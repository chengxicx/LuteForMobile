import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/content_service.dart';
import 'package:song_mobile/features/reader/services/epub_offline_prefetch.dart';
import 'package:song_mobile/features/reader/services/epub_offline_store.dart';

import 'epub_offline_html_test.dart' show samplePage;

class _MockApiService extends Mock implements ApiService {}

class _MockContentService extends Mock implements ContentService {}

Response<String> _stringResponse(String data) => Response<String>(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: '/test'),
);

Response<List<int>> _bytesResponse(List<int> data) => Response<List<int>>(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: '/test'),
);

void main() {
  late Directory temp;
  late EpubOfflineStore store;
  late _MockApiService api;
  late _MockContentService content;
  late EpubOfflinePrefetch prefetch;

  setUpAll(() {
    registerFallbackValue(0);
    registerFallbackValue('');
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('epub_offline_prefetch_');
    store = EpubOfflineStore(rootDir: temp.path);
    api = _MockApiService();
    content = _MockContentService();
    prefetch = EpubOfflinePrefetch(
      apiService: api,
      contentService: content,
      store: store,
    );

    when(() => api.baseUrl).thenReturn('https://lute.example.com');
    when(() => content.preloadPage(any(), any()))
        .thenAnswer((_) async {});
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  void stubPage(int bookId, int page, String html) {
    when(() => api.getEpubRenderPage(bookId, page))
        .thenAnswer((_) async => _stringResponse(html));
  }

  void stubAssets() {
    when(() => api.downloadAsset(any())).thenAnswer(
      (inv) async => _bytesResponse([1, 2, 3]),
    );
    // Both scoped stylesheets point at one more image (css recursion).
    when(
      () => api.downloadAsset(any(that: endsWith('.css'))),
    ).thenAnswer(
      (_) async => _bytesResponse(
        utf8.encode('a { background: url("img/bg.png"); }'),
      ),
    );
  }

  test('downloadPack stores pages, recursed assets, readings and completes',
      () async {
    stubPage(5, 1, samplePage);
    stubPage(5, 2, samplePage);
    stubAssets();
    when(() => api.postShadowingReadings(any())).thenAnswer(
      (_) async => _stringResponse('{"tokens":[]}'),
    );

    final progressCalls = <EpubOfflineProgress>[];
    final manifest = await prefetch.downloadPack(
      bookId: 5,
      title: '雪国',
      pageCount: 2,
      onProgress: progressCalls.add,
    );

    expect(manifest.complete, isTrue);
    expect(await store.hasPage(5, 1), isTrue);
    expect(await store.hasPage(5, 2), isTrue);

    // Assets from the page itself ...
    expect(await store.hasFile('static/css/styles.css'), isTrue);
    expect(await store.hasFile('static/epub/u1/img/ch1.jpg'), isTrue);
    // ... plus the css-recursed one ...
    expect(await store.hasFile('static/epub/u1/img/bg.png'), isTrue);
    // ... plus the furigana script the serve-time rewrite injects.
    expect(await store.hasFile('static/js/lute-furigana.js'), isTrue);

    // Readings: one POST per word-bearing paragraph; the identical
    // second page hits the stored keys and POSTs nothing new.
    verify(
      () => api.postShadowingReadings(any()),
    ).called(3);
    expect(
      await store.readReadings(
        EpubOfflineStore.canonicalReadingsKey(9, ['猫', 'が']),
      ),
      '{"tokens":[]}',
    );

    // The Hive fragment cache was primed for both pages.
    verify(() => content.preloadPage(5, 1)).called(1);
    verify(() => content.preloadPage(5, 2)).called(1);

    expect(progressCalls.last.pagesDone, 2);
    expect(progressCalls.last.pageCount, 2);
  });

  test('a finished download resumes without re-fetching pages', () async {
    stubPage(5, 1, samplePage);
    stubPage(5, 2, samplePage);
    stubAssets();
    when(() => api.postShadowingReadings(any())).thenAnswer(
      (_) async => _stringResponse('{"tokens":[]}'),
    );

    await prefetch.downloadPack(bookId: 5, title: 't', pageCount: 2);
    await prefetch.downloadPack(bookId: 5, title: 't', pageCount: 2);

    verify(() => api.getEpubRenderPage(5, 1)).called(1);
    verify(() => api.getEpubRenderPage(5, 2)).called(1);
  });

  test('cancellation keeps the partial manifest', () async {
    stubPage(5, 1, samplePage);
    stubPage(5, 2, samplePage);
    stubAssets();
    when(() => api.postShadowingReadings(any())).thenAnswer(
      (_) async => _stringResponse('{"tokens":[]}'),
    );

    var cancelChecks = 0;
    final manifest = await prefetch.downloadPack(
      bookId: 5,
      title: 't',
      pageCount: 2,
      // Lets page 1 through, stops before page 2.
      shouldCancel: () => ++cancelChecks > 1,
    );

    expect(manifest.complete, isFalse);
    expect(manifest.pageTimestamps, contains(1));
    expect(manifest.pageTimestamps, isNot(contains(2)));
    verifyNever(() => api.getEpubRenderPage(5, 2));
  });

  test('a page failure aborts with the partial manifest saved', () async {
    stubPage(5, 1, samplePage);
    when(
      () => api.getEpubRenderPage(5, 2),
    ).thenThrow(Exception('boom'));
    stubAssets();
    when(() => api.postShadowingReadings(any())).thenAnswer(
      (_) async => _stringResponse('{"tokens":[]}'),
    );

    await expectLater(
      prefetch.downloadPack(bookId: 5, title: 't', pageCount: 2),
      throwsException,
    );

    final saved = await store.manifestFor(5);
    expect(saved, isNotNull);
    expect(saved!.pageTimestamps, contains(1));
    expect(saved.complete, isFalse);
  });

  test('asset failures do not abort the download', () async {
    stubPage(5, 1, samplePage);
    when(() => api.downloadAsset(any())).thenThrow(Exception('asset down'));
    when(() => api.postShadowingReadings(any())).thenThrow(Exception('no readings'));

    final manifest = await prefetch.downloadPack(
      bookId: 5,
      title: 't',
      pageCount: 1,
    );

    expect(manifest.complete, isTrue);
    expect(await store.hasPage(5, 1), isTrue);
    expect(await store.hasFile('static/css/styles.css'), isFalse);
  });
}
