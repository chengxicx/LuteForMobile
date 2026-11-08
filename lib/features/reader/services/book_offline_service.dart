import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/audio_cache_service.dart';
import '../../../core/cache/providers/audio_cache_provider.dart';
import '../../../core/cache/providers/page_cache_provider.dart';
import '../../../core/network/content_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/network_providers.dart';
import '../../books/models/book.dart';
import '../models/page_cache_entry.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/epub_offline_provider.dart';
import 'epub_offline_prefetch.dart';
import 'epub_offline_store.dart';
import 'manga_image_cache.dart';
import 'page_cache_service.dart';
import 'pdf_file_service.dart';

/// Download progress / state of one book's offline copy.
///
/// The unit depends on the book type: pages for text books and manga,
/// chapters for EPUB packs, bytes for PDF files.
class BookOfflineTask {
  const BookOfflineTask({
    required this.bookId,
    required this.done,
    required this.total,
    required this.running,
    required this.unit,
    this.error,
  });

  final int bookId;
  final int done;

  /// 0 / -1 when the size is not known (PDF without Content-Length).
  final int total;
  final bool running;
  final BookOfflineUnit unit;
  final String? error;

  double? get fraction {
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }
}

enum BookOfflineUnit { pages, chapters, bytes }

/// One book as it exists on this device: page-cache coverage, EPUB pack,
/// audio bytes and PDF file size, aggregated so the details dialog can
/// answer "is this book offline?" in one line.
class BookOfflineStatus {
  const BookOfflineStatus({
    required this.bookId,
    required this.bookType,
    required this.totalPages,
    required this.cachedPages,
    required this.cachedBytes,
    required this.packedPages,
    required this.epubComplete,
    required this.pdfBytes,
    required this.audioBytes,
    required this.pinned,
    required this.imageFiles,
    required this.imageBytes,
  });

  final int bookId;

  /// Normalised type: `''` → text, `manga`, `pdf`, `epub`, ...
  final String bookType;

  final int totalPages;

  /// Pages present in the Hive page cache (expired pages excluded).
  final int cachedPages;
  final int cachedBytes;

  /// EPUB offline-pack chapters.
  final int packedPages;
  final bool epubComplete;

  final int pdfBytes;
  final int audioBytes;

  /// Whether the page cache for this book is pinned (explicit download).
  final bool pinned;

  /// Manga page images in the self-managed image cache.
  final int imageFiles;
  final int imageBytes;

  bool get isPdf => bookType == 'pdf';
  bool get isEpub => bookType == 'epub';
  bool get isManga => bookType == 'manga';

  String get unitLabel => isEpub ? 'chapters' : 'pages';

  /// Units already offline for the row's "N/M" label.
  int get unitsDone => isEpub ? packedPages : cachedPages;

  bool get isComplete {
    if (isPdf) return pdfBytes > 0;
    if (isEpub) return epubComplete || (totalPages > 0 && packedPages >= totalPages);
    if (isManga) {
      return totalPages > 0 &&
          cachedPages >= totalPages &&
          imageFiles >= totalPages;
    }
    return totalPages > 0 && cachedPages >= totalPages;
  }

  /// The book has *something* offline; the row switches to Update/Delete.
  bool get hasAnything =>
      cachedPages > 0 || packedPages > 0 || pdfBytes > 0 || imageFiles > 0;
}

class BookOfflineService {
  BookOfflineService({
    required PageCacheService pageCache,
    required ContentService contentService,
    required EpubOfflinePrefetch epubPrefetch,
    required EpubOfflineStore epubStore,
    required AudioCacheService audioCache,
    required PdfFileService pdfFile,
    required MangaImageCache mangaCache,
    required String Function() serverUrl,
  }) : _pageCache = pageCache,
       _contentService = contentService,
       _epubPrefetch = epubPrefetch,
       _epubStore = epubStore,
       _audioCache = audioCache,
       _pdfFile = pdfFile,
       _mangaCache = mangaCache,
       _serverUrl = serverUrl;

  final PageCacheService _pageCache;
  final ContentService _contentService;
  final EpubOfflinePrefetch _epubPrefetch;
  final EpubOfflineStore _epubStore;
  final AudioCacheService _audioCache;
  final PdfFileService _pdfFile;
  final MangaImageCache _mangaCache;
  final String Function() _serverUrl;

  /// Live task state, keyed by book id. The dialog listens to it, so a
  /// download keeps reporting after the dialog is reopened -- the work
  /// itself is not tied to the dialog or the reader's page lifecycle.
  final ValueNotifier<Map<int, BookOfflineTask>> tasks =
      ValueNotifier<Map<int, BookOfflineTask>>(const {});

  final Set<int> _running = <int>{};
  final Map<int, bool> _cancelFlags = <int, bool>{};

  bool isRunning(int bookId) => _running.contains(bookId);

  void cancel(int bookId) {
    if (!_running.contains(bookId)) return;
    _cancelFlags[bookId] = true;
  }

  static String typeOf(Book book) {
    final raw = book.bookType.trim().toLowerCase();
    if (raw.isEmpty) return 'text';
    return raw;
  }

  BookOfflineUnit unitFor(Book book) {
    final type = typeOf(book);
    if (type == 'epub') return BookOfflineUnit.chapters;
    if (type == 'pdf') return BookOfflineUnit.bytes;
    return BookOfflineUnit.pages;
  }

  /// Aggregate on-disk state for [book].
  Future<BookOfflineStatus> statusFor(Book book) async {
    final type = typeOf(book);
    final pages = await _pageCache.getBookStats(book.id);

    var packedPages = 0;
    var epubComplete = false;
    if (type == 'epub') {
      final manifest = await _epubStore.manifestFor(book.id);
      packedPages = manifest?.pageTimestamps.length ?? 0;
      epubComplete = manifest?.complete ?? false;
    }

    final pdfBytes = type == 'pdf'
        ? await _pdfFile.localPdfBytes(book.id)
        : 0;

    final audioBytes = book.hasAudio ? await _audioCache.bytesForBook(book.id) : 0;

    var imageFiles = 0;
    var imageBytes = 0;
    if (type == 'manga') {
      final images = await _mangaCache.statsForBook(book.id);
      imageFiles = images.files;
      imageBytes = images.bytes;
    }

    return BookOfflineStatus(
      bookId: book.id,
      bookType: type,
      totalPages: book.totalPages,
      cachedPages: pages.pages,
      cachedBytes: pages.bytes,
      packedPages: packedPages,
      epubComplete: epubComplete,
      pdfBytes: pdfBytes,
      audioBytes: audioBytes,
      pinned: pages.pinned,
      imageFiles: imageFiles,
      imageBytes: imageBytes,
    );
  }

  /// Starts (or resumes) a whole-book offline download.
  ///
  /// Idempotent per book: a second call while the first runs is ignored.
  Future<void> download(Book book, {bool forceRefresh = false}) async {
    final bookId = book.id;
    if (_running.contains(bookId)) return;

    _running.add(bookId);
    _cancelFlags[bookId] = false;
    final wasPinned = _pageCache.isBookPinned(bookId);
    _publish(
      BookOfflineTask(
        bookId: bookId,
        done: 0,
        total: book.totalPages,
        running: true,
        unit: unitFor(book),
      ),
    );

    try {
      switch (typeOf(book)) {
        case 'epub':
          await _downloadEpub(book, forceRefresh: forceRefresh);
        case 'pdf':
          await _downloadPdf(book);
        default:
          await _downloadPages(book);
      }
      final status = await statusFor(book);
      _publish(
        BookOfflineTask(
          bookId: bookId,
          done: unitFor(book) == BookOfflineUnit.bytes
              ? status.pdfBytes
              : status.unitsDone,
          total: unitFor(book) == BookOfflineUnit.bytes
              ? status.pdfBytes
              : book.totalPages,
          running: false,
          unit: unitFor(book),
        ),
      );
    } catch (e) {
      // 失败/中断的下载解除 pin：已经落盘的页留在普通缓存里，但不能再
      // 承诺"这本书以后都在"。
      if (!wasPinned) await _pageCache.unpinBook(bookId);
      _publish(
        BookOfflineTask(
          bookId: bookId,
          done: 0,
          total: book.totalPages,
          running: false,
          unit: unitFor(book),
          error: e.toString().replaceFirst('Exception: ', ''),
        ),
      );
      rethrow;
    } finally {
      _running.remove(bookId);
      _cancelFlags.remove(bookId);
    }
  }

  /// Removes everything this app stored for the book: the EPUB pack, the
  /// local PDF, and the page cache (which also clears the pin).
  ///
  /// Audio is left alone on purpose: it is a separate 6-64MB download the
  /// user may want to keep, and the settings screen owns its lifecycle.
  Future<void> deleteOffline(Book book) async {
    final type = typeOf(book);
    if (type == 'epub') await _epubStore.deletePack(book.id);
    if (type == 'pdf') await _pdfFile.deleteLocalPdfs(book.id);
    if (type == 'manga') await _mangaCache.deleteForBook(book.id);
    await _pageCache.clearBookCache(book.id);
    final remaining = Map<int, BookOfflineTask>.of(tasks.value)
      ..remove(book.id);
    tasks.value = remaining;
  }

  bool _isCancelled(int bookId) => _cancelFlags[bookId] ?? false;

  Future<void> _downloadEpub(Book book, {required bool forceRefresh}) async {
    await _pageCache.pinBook(book.id);
    final manifest = await _epubPrefetch.downloadPack(
      bookId: book.id,
      title: book.title,
      pageCount: book.totalPages,
      forceRefresh: forceRefresh,
      onProgress: (progress) {
        _publish(
          BookOfflineTask(
            bookId: book.id,
            done: progress.pagesDone,
            total: progress.pageCount,
            running: true,
            unit: BookOfflineUnit.chapters,
          ),
        );
      },
      shouldCancel: () => _isCancelled(book.id),
    );
    if (_isCancelled(book.id)) await _pageCache.unpinBook(book.id);
    _publish(
      BookOfflineTask(
        bookId: book.id,
        done: manifest.pageTimestamps.length,
        total: manifest.pageCount,
        running: false,
        unit: BookOfflineUnit.chapters,
      ),
    );
  }

  /// Text books and manga: fetch every page into the Hive cache (pinned),
  /// plus the page image for manga.
  ///
  /// Runs outside the reader: nothing here reads ReaderState, so closing
  /// the book or the dialog does not stop the walk. Cancelling leaves what
  /// already landed in the ordinary cache.
  Future<void> _downloadPages(Book book) async {
    final total = book.totalPages;
    if (total <= 0) {
      throw Exception('This book has no pages to download.');
    }
    final isManga = typeOf(book) == 'manga';
    await _pageCache.pinBook(book.id);

    final stats = await _pageCache.getBookStats(book.id);
    var done = stats.pages;
    _publish(
      BookOfflineTask(
        bookId: book.id,
        done: done,
        total: total,
        running: true,
        unit: BookOfflineUnit.pages,
      ),
    );

    // Metadata is per-book static except #page_num, which preloadPage
    // patches per page -- reuse one copy instead of a structure request
    // per page.
    String? metadata = stats.lastPage == null
        ? null
        : await _pageCache.getMetadataFromCache(book.id, stats.lastPage!);

    for (var page = 1; page <= total; page++) {
      if (_isCancelled(book.id)) break;
      var entry = await _pageCache.getFromCache(book.id, page);
      var justDownloaded = false;

      if (entry == null) {
        await _contentService.preloadPage(
          book.id,
          page,
          cachedMetadataHtml: metadata,
        );
        entry = await _pageCache.getFromCache(book.id, page);
        if (entry == null) {
          throw Exception(
            'Could not download page $page. Check the connection and retry.',
          );
        }
        metadata ??= entry.metadataHtml;
        done++;
        justDownloaded = true;
        _publish(
          BookOfflineTask(
            bookId: book.id,
            done: done,
            total: total,
            running: true,
            unit: BookOfflineUnit.pages,
          ),
        );
      } else {
        metadata ??= entry.metadataHtml;
      }

      // 页 HTML 与页图是两次下载；整本离线对漫画来说两样都得有，
      // 否则断网翻页只能看到空白框。
      if (isManga) {
        await _ensureMangaImage(book, page, entry);
      }

      if (justDownloaded) {
        // Gentle pacing: the download should not saturate the request
        // queue the reader itself is using.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    if (_isCancelled(book.id)) await _pageCache.unpinBook(book.id);
  }

  Future<void> _ensureMangaImage(
    Book book,
    int page,
    PageCacheEntry entry,
  ) async {
    final manga = _contentService.parser
        .parsePage(
          entry.pageTextHtml,
          entry.metadataHtml,
          bookId: book.id,
        )
        .mangaPage;
    if (manga == null || manga.imagePath.isEmpty) return;
    final file = await _mangaCache.ensure(book.id, manga.imagePath);
    if (file == null) {
      throw Exception(
        'Could not download the image for page $page. '
        'Check the connection and retry.',
      );
    }
  }

  Future<void> _downloadPdf(Book book) async {
    final pageNum = book.currentPage > 0 ? book.currentPage : 1;
    final pageData = await _contentService.getPageContent(
      book.id,
      pageNum: pageNum,
      mode: ContentMode.reading,
    );
    final pdfPath = pageData?.pdfPage?.pdfPath ?? '';
    if (pdfPath.isEmpty) {
      throw Exception('Could not find the PDF file for this book.');
    }
    final url = pdfPath.startsWith('http')
        ? pdfPath
        : '${_serverUrl()}$pdfPath';

    var lastDone = 0;
    var lastTotal = 0;
    await _pdfFile.ensureLocalPdf(
      book.id,
      url,
      SessionManager.authHeaders(),
      onProgress: (received, total) {
        lastDone = received;
        lastTotal = total;
        _publish(
          BookOfflineTask(
            bookId: book.id,
            done: received,
            total: total,
            running: true,
            unit: BookOfflineUnit.bytes,
          ),
        );
      },
    );
    _publish(
      BookOfflineTask(
        bookId: book.id,
        done: lastDone,
        total: lastTotal,
        running: false,
        unit: BookOfflineUnit.bytes,
      ),
    );
  }

  void _publish(BookOfflineTask task) {
    final next = Map<int, BookOfflineTask>.of(tasks.value);
    next[task.bookId] = task;
    tasks.value = next;
  }
}

final bookOfflineServiceProvider = Provider<BookOfflineService>((ref) {
  return BookOfflineService(
    pageCache: ref.watch(pageCacheServiceProvider),
    contentService: ref.watch(contentServiceProvider),
    epubPrefetch: ref.watch(epubOfflinePrefetchProvider),
    epubStore: ref.watch(epubOfflineStoreProvider),
    audioCache: ref.watch(audioCacheServiceProvider),
    pdfFile: ref.watch(pdfFileServiceProvider),
    mangaCache: ref.watch(mangaImageCacheProvider),
    serverUrl: () => ref.read(settingsProvider).serverUrl,
  );
});
