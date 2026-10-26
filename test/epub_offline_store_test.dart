import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/services/epub_offline_store.dart';

void main() {
  late Directory temp;
  late EpubOfflineStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('epub_offline_store_');
    store = EpubOfflineStore(rootDir: temp.path);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('normalizeUrlPath', () {
    test('absolute path with query and fragment', () {
      expect(
        EpubOfflineStore.normalizeUrlPath(
          '/static/epub/u1/lute.css?v=abc#x',
          serverOrigin: 'https://lute.example.com',
        ),
        'static/epub/u1/lute.css',
      );
    });

    test('same-origin absolute url', () {
      expect(
        EpubOfflineStore.normalizeUrlPath(
          'https://lute.example.com/static/js/x.js?v=1',
          serverOrigin: 'https://lute.example.com',
        ),
        'static/js/x.js',
      );
    });

    test('foreign origin is rejected', () {
      expect(
        EpubOfflineStore.normalizeUrlPath(
          'https://cdn.example.com/font.woff',
          serverOrigin: 'https://lute.example.com',
        ),
        isNull,
      );
    });

    test('protocol-relative, data and traversal are rejected', () {
      const origin = 'https://lute.example.com';
      expect(
        EpubOfflineStore.normalizeUrlPath('//cdn.example.com/x', serverOrigin: origin),
        isNull,
      );
      expect(
        EpubOfflineStore.normalizeUrlPath('data:image/png;base64,xxx', serverOrigin: origin),
        isNull,
      );
      expect(
        EpubOfflineStore.normalizeUrlPath('/static/../etc/passwd', serverOrigin: origin),
        isNull,
      );
      expect(EpubOfflineStore.normalizeUrlPath('', serverOrigin: origin), isNull);
      expect(EpubOfflineStore.normalizeUrlPath('#frag', serverOrigin: origin), isNull);
    });
  });

  group('files', () {
    test('write / read / has roundtrip', () async {
      await store.writeText('read/epub_render/3/1', '<html>x</html>');
      expect(await store.hasPage(3, 1), isTrue);
      expect(await store.readText('read/epub_render/3/1'), '<html>x</html>');

      final bytes = utf8.encode('not really a jpg');
      await store.writeBytes('static/epub/u1/img/a.jpg', bytes);
      final read = await store.readBytes('static/epub/u1/img/a.jpg');
      expect(read, bytes);
      expect(await store.hasPage(3, 2), isFalse);
    });
  });

  group('readings', () {
    test('key is stable across whitespace and full_text is not identity', () {
      final a = EpubOfflineStore.canonicalReadingsKey(9, ['猫', 'が', '好き']);
      final b = EpubOfflineStore.canonicalReadingsKey(9, ['猫', 'が', '好き']);
      expect(a, b);
      expect(EpubOfflineStore.canonicalReadingsKey(9, ['猫']), isNot(a));
      expect(EpubOfflineStore.canonicalReadingsKey(8, ['猫', 'が', '好き']), isNot(a));
    });

    test('roundtrip through disk', () async {
      const body = '{"tokens":[{"reading":"ねこ"}]}';
      final key = EpubOfflineStore.canonicalReadingsKey(9, ['猫']);
      await store.writeReadings(key, body);
      expect(await store.hasReadings(key), isTrue);
      expect(await store.readReadings(key), body);
      expect(
        await store.readReadings(EpubOfflineStore.canonicalReadingsKey(9, ['犬'])),
        isNull,
      );
    });
  });

  group('manifest', () {
    test('json roundtrip keeps pages, urls and flags', () async {
      final manifest = EpubPackManifest(
        bookId: 7,
        title: '雪国',
        pageCount: 3,
        complete: true,
        pageTimestamps: {1: 100, 2: 200, 3: 300},
        urls: ['static/epub/u7/lute.css'],
      );
      await store.saveManifest(manifest);

      final loaded = await store.manifestFor(7);
      expect(loaded, isNotNull);
      expect(loaded!.title, '雪国');
      expect(loaded.pageCount, 3);
      expect(loaded.complete, isTrue);
      expect(loaded.pageTimestamps, {1: 100, 2: 200, 3: 300});
      expect(loaded.urls, ['static/epub/u7/lute.css']);
      expect(loaded.hasAllPages, isTrue);
    });

    test('hasAllPages is false when a page is missing', () {
      final manifest = EpubPackManifest(
        bookId: 7,
        pageCount: 3,
        pageTimestamps: {1: 100, 3: 300},
      );
      expect(manifest.hasAllPages, isFalse);
    });

    test('removePages drops entries and files, demotes complete', () async {
      final manifest = EpubPackManifest(
        bookId: 7,
        pageCount: 2,
        complete: true,
        pageTimestamps: {1: 100, 2: 200},
      );
      await store.saveManifest(manifest);
      await store.writeText(EpubOfflineStore.pageUrlPath(7, 1), 'p1');
      await store.writeText(EpubOfflineStore.pageUrlPath(7, 2), 'p2');

      await store.removePages(7, [2]);

      expect(await store.hasPage(7, 2), isFalse);
      expect(await store.hasPage(7, 1), isTrue);
      final loaded = await store.manifestFor(7);
      expect(loaded!.pageTimestamps, {1: 100});
      expect(loaded.complete, isFalse);
    });

    test('removePages without a manifest is a no-op', () async {
      await store.removePages(99, [1]);
    });
  });

  group('deletePack', () {
    test('removes pages, own epub assets and manifest; keeps shared files',
        () async {
      final manifest = EpubPackManifest(
        bookId: 7,
        pageCount: 1,
        complete: true,
        pageTimestamps: {1: 100},
        urls: [
          'static/epub/u7/lute.css',
          'static/css/styles.css',
        ],
      );
      await store.saveManifest(manifest);
      await store.writeText(EpubOfflineStore.pageUrlPath(7, 1), 'p1');
      await store.writeText('static/epub/u7/lute.css', 'css');
      await store.writeText('static/epub/u7/img/a.jpg', 'img');
      await store.writeText('static/css/styles.css', 'shared');

      await store.deletePack(7);

      expect(await store.manifestFor(7), isNull);
      expect(await store.hasPage(7, 1), isFalse);
      expect(await store.hasFile('static/epub/u7/lute.css'), isFalse);
      expect(await store.hasFile('static/epub/u7/img/a.jpg'), isFalse);
      // Shared assets belong to other packs too.
      expect(await store.hasFile('static/css/styles.css'), isTrue);
    });

    test('diskUsageBytes counts written files', () async {
      expect(await store.diskUsageBytes(), 0);
      await store.writeText('static/css/styles.css', '0123456789');
      expect(await store.diskUsageBytes(), 10);
    });
  });
}
