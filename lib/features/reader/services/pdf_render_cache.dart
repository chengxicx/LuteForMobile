import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../../core/logger/api_logger.dart';

/// Opens a book's PDF file once and renders its pages to [ui.Image]s with
/// a small LRU.
///
/// The reader recreates the page widget on every turn (it is keyed by
/// book+page), so the document handle and the rendered pages must live
/// somewhere that survives that: this provider-level cache.  With the
/// next page prefetched into the LRU a page turn is a cache hit -- no
/// re-parse, no re-render.
///
/// Rendered images are keyed by book, page and target pixel width (the
/// render resolution follows the viewport; a rotation or zoom-level
/// change simply produces a new key and re-renders once).
class PdfRenderCache {
  PdfDocument? _document;
  String? _documentSource;

  Future<PdfDocument>? _documentOpen;

  /// Rendered pages, keyed `bookId:pageNum:pixelWidth`, insertion-ordered
  /// so eviction drops the oldest.
  final Map<String, ui.Image> _images = {};

  /// Renders started but not finished yet, so concurrent requests for the
  /// same page (current page + prefetch) share one render.
  final Map<String, Future<ui.Image?>> _inFlight = {};

  /// Decoded pages are big (a 1200px-wide page is ~7MB of pixels); four
  /// of them cover current + one prefetched neighbour with headroom.
  static const int _maxImages = 4;

  /// Renders [pageNum] (1-based) of the PDF at [filePath] into a
  /// [ui.Image] [pixelWidth] pixels wide, serving it from the cache when
  /// possible.  Returns null when rendering fails -- the caller shows a
  /// retryable error rather than crashing.
  Future<ui.Image?> renderPage({
    required int bookId,
    required String filePath,
    required int pageNum,
    required int pixelWidth,
  }) async {
    if (pixelWidth < 1) return null;
    final key = '$bookId:$pageNum:$pixelWidth';
    final cached = _images[key];
    if (cached != null) return cached;
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final future = _render(bookId, filePath, pageNum, pixelWidth, key);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<ui.Image?> _render(
    int bookId,
    String filePath,
    int pageNum,
    int pixelWidth,
    String key,
  ) async {
    try {
      final document = await _documentFor(bookId, filePath);
      if (pageNum < 1 || pageNum > document.pages.length) return null;
      final page = document.pages[pageNum - 1];
      final fullHeight = pixelWidth * page.height / page.width;
      final rendered = await page.render(
        fullWidth: pixelWidth.toDouble(),
        fullHeight: fullHeight,
      );
      if (rendered == null) return null;
      final image = await rendered.createImage();
      rendered.dispose();
      _images[key] = image;
      _evict();
      return image;
    } catch (e) {
      ApiLogger.logError(
        'pdfRender',
        e,
        details: 'bookId=$bookId, page=$pageNum, width=$pixelWidth',
      );
      return null;
    }
  }

  /// The open document for [bookId], opening (and replacing) it when a
  /// different file is requested.  Opens are chained, so a request that
  /// arrives mid-open waits and then re-checks instead of opening a
  /// second document.
  Future<PdfDocument> _documentFor(int bookId, String filePath) {
    final source = '$bookId:$filePath';
    final document = _document;
    if (document != null && _documentSource == source) {
      return SynchronousFuture<PdfDocument>(document);
    }
    final previous = _documentOpen;
    final future = (previous ?? Future<void>.value()).then((_) async {
      if (_documentSource == source && _document != null) {
        return _document!;
      }
      final old = _document;
      _document = null;
      _documentSource = null;
      await old?.dispose();
      final opened = await PdfDocument.openFile(filePath);
      // The old book's rendered pages are meaningless for the new one.
      _clearImages();
      _document = opened;
      _documentSource = source;
      return opened;
    });
    _documentOpen = future;
    return future;
  }

  void _evict() {
    while (_images.length > _maxImages) {
      _images.remove(_images.keys.first)?.dispose();
    }
  }

  void _clearImages() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  void dispose() {
    _clearImages();
    _document?.dispose();
    _document = null;
    _documentSource = null;
  }
}

final pdfRenderCacheProvider = Provider<PdfRenderCache>((ref) {
  final cache = PdfRenderCache();
  ref.onDispose(cache.dispose);
  return cache;
});
