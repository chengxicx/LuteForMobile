import 'dart:convert';

import '../../../core/logger/api_logger.dart';
import '../../../core/network/api_service.dart';
import '../../../core/network/content_service.dart';
import 'epub_offline_html.dart';
import 'epub_offline_store.dart';

/// Progress of a full-pack download: whole chapters done (assets and
/// readings ride along with their page).
class EpubOfflineProgress {
  const EpubOfflineProgress({required this.pagesDone, required this.pageCount});
  final int pagesDone;
  final int pageCount;
}

/// Builds and refreshes the EPUB offline packs.
///
/// A pack download walks every chapter page of the book
/// (`/read/epub_render/<bookId>/<p>`), stores the canonical HTML, then
/// mines and stores its same-origin subresources (stylesheets -- with
/// one recursion into their `url()`/`@import` references for fonts and
/// images --, scripts, chapter images), the per-paragraph furigana
/// readings, and primes the Hive page-fragment cache via [ContentService.preloadPage]
/// so offline page *turns* have data too.
///
/// Resumable by design: every finished page lands in the manifest, and
/// [downloadPack] skips pages it already has unless [forceRefresh].
/// Asset and reading failures are skipped (a missing image must not
/// abort a 300-page book); only a page-HTML failure propagates.
class EpubOfflinePrefetch {
  /// How long a packed chapter page is considered current (see
  /// [prefetchNearby]).
  static const Duration packedPageTtl = Duration(hours: 6);

  final ApiService apiService;
  final ContentService contentService;
  final EpubOfflineStore store;

  EpubOfflinePrefetch({
    required this.apiService,
    required this.contentService,
    required this.store,
  });

  /// Books with a full download in flight (guards the manual button and
  /// keeps prefetchNearby from racing it).
  final Set<int> _runningBooks = {};

  /// Assets that failed this session; not retried for every page.
  final Set<String> _failedAssets = {};

  /// `bookId_page` nearby pages already handled this session.
  final Set<String> _nearbyDone = {};

  /// Pack assets re-fetched this session (see [refreshMutableAssets]).
  bool _mutableAssetsRefreshed = false;

  /// Re-fetch the pack assets whose URL is stable but whose content is
  /// not.
  ///
  /// A pack stores these under the bare path, so a copy written when the
  /// pack was built outlives every server-side change -- and a WebView
  /// loading the pack has no way to revalidate it.  Three things ride on
  /// that: the per-user theme (the paper painted by the look classes),
  /// styles.css (where those classes are defined at all) and
  /// lute-epub-reader.js (which holds `setLook`, the function the app's
  /// look chips call).  A stale js is why *Original / Night / Theme* did
  /// nothing: the bridge call reached a page whose reader script had no
  /// `setLook`, so the chips were accepted and silently dropped.
  ///
  /// Runs before a chapter is served from the pack, so the palette is
  /// right on the first paint.  The theme is a few KB and is refreshed
  /// every time; the rest are ~200 KB together, so once a session is
  /// enough.
  Future<void> refreshMutableAssets() async {
    await _refreshAsset('theme/current');
    if (_mutableAssetsRefreshed) return;
    _mutableAssetsRefreshed = true;
    await _refreshAsset('static/css/styles.css');
    await _refreshAsset('static/js/lute-epub-reader.js');
    await _refreshAsset('static/js/lute-furigana.js');
  }

  Future<void> _refreshAsset(String path) async {
    try {
      // The mutable assets sit behind the CDN, which serves them with
      // `Cache-Control: immutable, max-age=1y`.  A refresh that asks for
      // the bare path therefore stores the CDN's copy -- measured at ten
      // hours old for the theme and twenty-one for styles.css -- and the
      // pack keeps it until the next refresh, forever.  A cache-busting
      // query makes every refresh a CDN miss, i.e. the origin's bytes.
      final bust = DateTime.now().millisecondsSinceEpoch;
      final asset = await apiService.downloadAsset('/$path?_=$bust');
      final bytes = asset.data;
      if (bytes == null || bytes.isEmpty) return;
      await store.writeBytes(path, bytes);
    } on Exception catch (e) {
      // Offline, or a transient failure: the packed copy stays, which is
      // what the reader had anyway.
      ApiLogger.logError('epubOfflineRefresh', e, details: path);
    }
  }

  bool get isRunning => _runningBooks.isNotEmpty;
  bool isRunningFor(int bookId) => _runningBooks.contains(bookId);

  /// Downloads (or resumes) the whole-book pack.
  ///
  /// Returns the saved manifest -- partial when [shouldCancel] stopped
  /// the walk or an error aborted it (the partial manifest is persisted
  /// either way, so the next call resumes).
  Future<EpubPackManifest> downloadPack({
    required int bookId,
    required String title,
    required int pageCount,
    bool forceRefresh = false,
    void Function(EpubOfflineProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (_runningBooks.contains(bookId)) {
      return (await store.manifestFor(bookId)) ??
          EpubPackManifest(bookId: bookId, title: title, pageCount: pageCount);
    }
    _runningBooks.add(bookId);
    try {
      final manifest =
          await store.manifestFor(bookId) ??
          EpubPackManifest(bookId: bookId, title: title, pageCount: pageCount);
      manifest.title = title;
      manifest.pageCount = pageCount;
      if (forceRefresh) manifest.pageTimestamps.clear();

      var pagesDone = manifest.pageTimestamps.length;
      onProgress?.call(
        EpubOfflineProgress(pagesDone: pagesDone, pageCount: pageCount),
      );

      for (var page = 1; page <= pageCount; page++) {
        if (shouldCancel?.call() ?? false) break;
        if (manifest.pageTimestamps.containsKey(page)) continue;
        try {
          await _fetchPageIntoPack(
            bookId: bookId,
            page: page,
            manifest: manifest,
          );
          manifest.pageTimestamps[page] =
              DateTime.now().millisecondsSinceEpoch;
          pagesDone++;
          onProgress?.call(
            EpubOfflineProgress(pagesDone: pagesDone, pageCount: pageCount),
          );
          await store.saveManifest(manifest);
        } on Exception catch (e, st) {
          // Persist the pages that made it, then surface the failure:
          // the bookshelf button shows the error and offers a resume.
          ApiLogger.logError('epubOfflineDownload', e, details: '$st');
          await store.saveManifest(manifest);
          rethrow;
        }
      }

      manifest.complete = manifest.hasAllPages;
      await store.saveManifest(manifest);
      return manifest;
    } finally {
      _runningBooks.remove(bookId);
    }
  }

  /// Best-effort cache of the chapters around the reader: the current
  /// page and the next one.  Runs after a successful *online* load, so
  /// it also refreshes already-packed pages (their assets are reused --
  /// content-hashed URLs never change behind a file).
  Future<void> prefetchNearby({
    required int bookId,
    required int page,
    required int pageCount,
  }) async {
    if (_runningBooks.contains(bookId)) return;
    final pages = {page, if (page + 1 <= pageCount) page + 1};

    try {
      final manifest =
          await store.manifestFor(bookId) ??
          EpubPackManifest(bookId: bookId, pageCount: pageCount);
      manifest.pageCount = pageCount;
      var changed = false;

      for (final p in pages) {
        if (!_nearbyDone.add('$bookId-$p')) continue;
        // A chapter packed within [packedPageTtl] is left alone: the old
        // behaviour re-rendered and re-downloaded the open chapter (380
        // KB here) on every single open, which is what "it loads every
        // time" felt like.  Status colours do not need it either -- the
        // reader pushes those down itself.
        final packed = manifest.pageTimestamps[p];
        if (packed != null &&
            DateTime.now().millisecondsSinceEpoch - packed <
                packedPageTtl.inMilliseconds) {
          continue;
        }
        try {
          await _fetchPageIntoPack(
            bookId: bookId,
            page: p,
            manifest: manifest,
          );
          manifest.pageTimestamps[p] = DateTime.now().millisecondsSinceEpoch;
          changed = true;
        } on Exception catch (e) {
          ApiLogger.logError('epubOfflineNearby', e, details: 'book $bookId page $p');
        }
      }

      if (changed) {
        manifest.complete = manifest.complete || manifest.hasAllPages;
        await store.saveManifest(manifest);
      }
    } on Exception catch (e) {
      ApiLogger.logError('epubOfflineNearby', e);
    }
  }

  /// One chapter page: HTML, assets (css recursed once per file),
  /// readings, and the Hive fragment cache.
  Future<void> _fetchPageIntoPack({
    required int bookId,
    required int page,
    required EpubPackManifest manifest,
  }) async {
    final response = await apiService.getEpubRenderPage(bookId, page);
    final pageHtml = response.data ?? '';
    if (pageHtml.isEmpty) {
      throw Exception('Empty chapter page $bookId/$page');
    }
    await store.writeText(EpubOfflineStore.pageUrlPath(bookId, page), pageHtml);

    // Assets: page references first, then one pass through every css
    // that arrives (fonts / background images / @imports).
    final pending = extractAssetPaths(
      pageHtml,
      serverOrigin: apiService.baseUrl,
    ).toList();
    // The furigana script is not referenced by the canonical
    // (furigana=0) page but is injected by the serve-time rewrite.
    pending.add('static/js/lute-furigana.js');

    final visited = <String>{};
    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!visited.add(path)) continue;
      if (_failedAssets.contains(path)) continue;

      if (await store.hasFile(path)) {
        manifest.urls.add(path);
        // A cached css still needs its refs enumerated when it was
        // first stored by another book: the manifest of *this* book
        // should know the whole closure for deletePack's dir cleanup.
        continue;
      }
      try {
        final asset = await apiService.downloadAsset('/$path');
        final bytes = asset.data;
        if (bytes == null) continue;
        await store.writeBytes(path, bytes);
        manifest.urls.add(path);
        if (path.toLowerCase().endsWith('.css')) {
          final cssText = utf8.decode(bytes, allowMalformed: true);
          pending.addAll(extractCssRefs(cssText, path));
        }
      } on Exception catch (e) {
        _failedAssets.add(path);
        ApiLogger.logError('epubOfflineAsset', e, details: path);
      }
    }

    // Furigana readings, batched exactly as the page's script will ask
    // for them (word tokens per paragraph), stored as the raw JSON the
    // local server replays verbatim.
    final reading = extractReadingBatches(pageHtml);
    if (reading != null) {
      for (final batch in reading.batches) {
        if (batch.isEmpty) continue;
        final key = EpubOfflineStore.canonicalReadingsKey(
          reading.langId,
          batch,
        );
        if (await store.hasReadings(key)) continue;
        try {
          final readingsResponse = await apiService.postShadowingReadings({
            'language_id': reading.langId,
            'tokens': batch,
            'full_text': batch.join(),
          });
          final body = readingsResponse.data;
          if (body != null && body.isNotEmpty) {
            await store.writeReadings(key, body);
          }
        } on Exception catch (e) {
          // Readings are an enhancement; a language without them (or a
          // transient failure) just leaves that paragraph unannotated
          // offline, same as the page's own fetch failure would.
          ApiLogger.logError('epubOfflineReadings', e);
        }
      }
    }

    // The reader turns pages through the Hive fragment cache, not the
    // render page -- prime it so offline page turns work too.
    try {
      await contentService.preloadPage(bookId, page);
    } on Exception catch (e) {
      ApiLogger.logError('epubOfflinePreload', e);
    }
  }
}
