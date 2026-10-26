import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/services/epub_local_server.dart';
import 'package:song_mobile/features/reader/services/epub_offline_store.dart';

import 'epub_offline_html_test.dart' show samplePage;

void main() {
  late Directory temp;
  late EpubOfflineStore store;
  late EpubLocalServer server;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('epub_local_server_');
    store = EpubOfflineStore(rootDir: temp.path);
    server = EpubLocalServer(store: store);

    // A packed chapter page plus its assets.
    await store.writeText(EpubOfflineStore.pageUrlPath(5, 1), samplePage);
    await store.writeBytes('static/epub/u1/img/ch1.jpg', [1, 2, 3, 4]);
    await store.writeText('static/css/styles.css', 'body {}');
  });

  tearDown(() async {
    await server.stop();
    await temp.delete(recursive: true);
  });

  Future<String> getBody(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  test('chapter page is served with the requested look/furigana/triple',
      () async {
    final base = await server.ensureStarted();
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        base.replace(
          path: '/read/epub_render/5/1',
          queryParameters: {
            'look': 'night',
            'furigana': '1',
            'triple': '1',
          },
        ),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(
        response.headers.contentType?.mimeType,
        'text/html',
      );
      final body = await getBody(response);
      expect(body, contains('epub-look-night'));
      expect(body, contains('var furiganaLoaded = true;'));
      expect(body, contains('var tripleEnabled = true;'));
      expect(body, contains('src="/static/js/lute-furigana.js"'));
    } finally {
      client.close();
    }
  });

  test('assets are served with their content type', () async {
    final base = await server.ensureStarted();
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        base.replace(path: '/static/epub/u1/img/ch1.jpg'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'image/jpeg');
      final bytes = <int>[];
      await for (final data in response) {
        bytes.addAll(data);
      }
      expect(bytes, [1, 2, 3, 4]);

      // Query strings are ignored (content-hashed URLs).
      final cssRequest = await client.getUrl(
        base.replace(
          path: '/static/css/styles.css',
          queryParameters: {'v': 'abc123'},
        ),
      );
      final cssResponse = await cssRequest.close();
      expect(cssResponse.statusCode, 200);
      expect(await getBody(cssResponse), 'body {}');
    } finally {
      client.close();
    }
  });

  test('missing paths are 404, non-GET/POST is 405', () async {
    final base = await server.ensureStarted();
    final client = HttpClient();
    try {
      final missing = await client.getUrl(
        base.replace(path: '/static/epub/u1/nope.jpg'),
      );
      expect((await missing.close()).statusCode, 404);

      final put = await client.openUrl(
        'PUT',
        base.replace(path: '/static/css/styles.css'),
      );
      expect((await put.close()).statusCode, 405);
    } finally {
      client.close();
    }
  });

  test('readings POST replays a stored response, 404 otherwise', () async {
    const known = '{"tokens":[{"reading":"ねこ"}]}';
    await store.writeReadings(
      EpubOfflineStore.canonicalReadingsKey(9, ['猫']),
      known,
    );

    final base = await server.ensureStarted();
    final client = HttpClient();
    try {
      final hit = await client.postUrl(
        base.replace(path: '/read/shadowing/readings'),
      );
      hit.headers.contentType = ContentType.json;
      hit.write(
        jsonEncode({
          'language_id': 9,
          'tokens': ['猫'],
          'full_text': '猫',
        }),
      );
      final hitResponse = await hit.close();
      expect(hitResponse.statusCode, 200);
      expect(await getBody(hitResponse), known);

      final miss = await client.postUrl(
        base.replace(path: '/read/shadowing/readings'),
      );
      miss.headers.contentType = ContentType.json;
      miss.write(jsonEncode({'language_id': 9, 'tokens': ['犬']}));
      expect((await miss.close()).statusCode, 404);
    } finally {
      client.close();
    }
  });

  test('localPageUrl returns null when the pack lacks the page', () async {
    expect(await server.localPageUrl(5, 2), isNull);
    final url = await server.localPageUrl(
      5,
      1,
      look: 'night',
      furigana: true,
      triple: true,
    );
    expect(url, isNotNull);
    expect(url!.host, '127.0.0.1');
    expect(url.path, '/read/epub_render/5/1');
    expect(url.queryParameters['look'], 'night');
    expect(url.queryParameters['furigana'], '1');
    expect(url.queryParameters['triple'], '1');
  });

  test('locally imported books are served from the /local/ root',
      () async {
    final localRoot =
        await Directory.systemTemp.createTemp('epub_local_root_');
    addTearDown(() async => localRoot.delete(recursive: true));
    final extract = Directory('${localRoot.path}/ab12/extract/OEBPS/text');
    await extract.create(recursive: true);
    await File('${extract.path}/ch1.xhtml').writeAsString('<p>hi</p>');

    final localServer = EpubLocalServer(
      store: store,
      localRootResolver: () async => localRoot.path,
    );
    addTearDown(localServer.stop);

    final base = await localServer.ensureStarted();
    final client = HttpClient();
    try {
      final ok = await client.getUrl(
        base.replace(path: '/local/ab12/OEBPS/text/ch1.xhtml'),
      );
      final okResponse = await ok.close();
      expect(okResponse.statusCode, 200);
      expect(await getBody(okResponse), '<p>hi</p>');
      expect(okResponse.headers.contentType?.mimeType, 'text/html');

      final miss = await client.getUrl(
        base.replace(path: '/local/ab12/OEBPS/missing.xhtml'),
      );
      expect((await miss.close()).statusCode, 404);
    } finally {
      client.close();
    }
  });

  test('/local/ without a resolver is 404', () async {
    final base = await server.ensureStarted();
    final client = HttpClient();
    try {
      final request = await client.getUrl(base.replace(path: '/local/x/y'));
      expect((await request.close()).statusCode, 404);
    } finally {
      client.close();
    }
  });
}
