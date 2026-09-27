import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/pdf_page.dart';
import '../models/text_item.dart';
import '../services/pdf_file_service.dart';
import '../services/pdf_render_cache.dart';
import 'page_turn_flick_listener.dart';

/// Renders one PDF book page: the page drawn natively (pdfium) with the
/// tokenized words overlaid as tappable, translucent status tints -- the
/// same contract as the web reader, where the printed glyphs live in the
/// rendered page and the word boxes only paint highlighter over them
/// (styles.css: "term status colors act as translucent highlighter tints
/// that let the printed text show through underneath").
///
/// The word boxes use percent coordinates of the page (estimated
/// server-side from pypdf geometry), so the overlay positions are exact
/// fractions of the laid-out page regardless of render resolution.
///
/// The whole PDF file is downloaded once to the app cache
/// ([PdfFileService]) and pages render locally ([PdfRenderCache], which
/// also keeps the next page rendered ahead of the turn), so after the
/// first open a page turn is a cache hit.
///
/// Gestures mirror [MangaPageView]: tap the right third of the page for
/// the next page, the left third for the previous one, a horizontal flick
/// turns the page (see [PageTurnFlickListener]), pinch to zoom, pan when
/// zoomed in.  Tapping a word opens the term popup, exactly like in the
/// text and manga readers.
class PdfPageView extends ConsumerStatefulWidget {
  final int bookId;
  final PdfPageData pdf;

  /// Absolute URL of the PDF file (`serverUrl` + [PdfPageData.pdfPath]).
  final String pdfUrl;
  final Map<String, String>? pdfHeaders;
  final void Function(bool forward)? onTurnPage;
  final void Function(TextItem, BuildContext)? onTap;
  final void Function(TextItem)? onLongPress;

  const PdfPageView({
    super.key,
    required this.bookId,
    required this.pdf,
    required this.pdfUrl,
    this.pdfHeaders,
    this.onTurnPage,
    this.onTap,
    this.onLongPress,
  });

  @override
  ConsumerState<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends ConsumerState<PdfPageView> {
  final TransformationController _transformation = TransformationController();

  /// Local copy of the PDF file, null while it is still downloading.
  String? _localPath;

  /// Download progress in bytes; total is -1 when undisclosed.
  int _received = 0;
  int _total = -1;

  /// The rendered current page; null until the first render lands.
  ui.Image? _pageImage;

  /// What [_pageImage] was rendered for, so a rebuilt layout (rotated
  /// device, different viewport width) re-renders at the right size.
  int? _renderedPage;
  int? _renderedWidth;

  String? _error;
  bool _renderScheduled = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  /// Download the file (first open only; later opens reuse the cached
  /// copy).  Rendering starts from the build/layout step, which knows the
  /// viewport width the render should target.
  Future<void> _bootstrap() async {
    try {
      final path = await ref
          .read(pdfFileServiceProvider)
          .ensureLocalPdf(
            widget.bookId,
            widget.pdfUrl,
            widget.pdfHeaders ?? const {},
            onProgress: (received, total) {
              if (!mounted) return;
              setState(() {
                _received = received;
                _total = total;
              });
            },
          );
      if (!mounted) return;
      setState(() => _localPath = path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to download PDF: $e');
    }
  }

  Future<void> _renderPage(int pageNum, int pixelWidth) async {
    final image = await ref
        .read(pdfRenderCacheProvider)
        .renderPage(
          bookId: widget.bookId,
          filePath: _localPath!,
          pageNum: pageNum,
          pixelWidth: pixelWidth,
        );
    if (!mounted) return;
    setState(() {
      _renderScheduled = false;
      if (image != null) {
        _pageImage = image;
        _renderedPage = pageNum;
        _renderedWidth = pixelWidth;
      } else if (_pageImage == null) {
        _error = 'Failed to render page $pageNum.';
      }
    });
    // Keep one page ahead of the reader: when the turn comes, the image
    // is already in the LRU.  Out-of-range page numbers fail soft in the
    // cache, so the last page can prefetch blindly.
    unawaited(_prefetchPage(pageNum + 1, pixelWidth));
  }

  Future<void> _prefetchPage(int pageNum, int pixelWidth) async {
    final path = _localPath;
    if (path == null) return;
    await ref
        .read(pdfRenderCacheProvider)
        .renderPage(
          bookId: widget.bookId,
          filePath: path,
          pageNum: pageNum,
          pixelWidth: pixelWidth,
        );
  }

  /// A tap on the paper outside every word: page-turn tap zones.  While
  /// zoomed in the visible area may sit inside any zone and taps are for
  /// reading (the manga rule).
  void _handleTapOnArt(Offset local, double pageWidth) {
    if (widget.onTurnPage == null) return;
    if (_transformation.value.getMaxScaleOnAxis() > 1.01) return;
    final dx = local.dx / pageWidth;
    if (dx >= 2 / 3) {
      widget.onTurnPage!(true);
    } else if (dx <= 1 / 3) {
      widget.onTurnPage!(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageTurnFlickListener(
      transformation: _transformation,
      onTurnPage: widget.onTurnPage,
      child: InteractiveViewer(
        constrained: false,
        panEnabled: true,
        minScale: 1.0,
        maxScale: 5.0,
        transformationController: _transformation,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewportWidth = constraints.maxWidth;
            final viewportHeight = constraints.maxHeight;

            // Fit width: the page fills the viewport width and pans
            // vertically, like the manga reader's default mode.
            final pageWidth = viewportWidth;
            final pageHeight =
                pageWidth * widget.pdf.pageHeight / widget.pdf.pageWidth;

            if (_error == null && _localPath != null) {
              _scheduleRenderIfNeeded(context, viewportWidth);
            }

            final pageContent = SizedBox(
              width: pageWidth,
              height: pageHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    // Tapping the paper (outside every word): page-turn
                    // tap zones.  Opaque: the tap must register even where
                    // the page image has nothing hit-testable of its own.
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        _handleTapOnArt(details.localPosition, pageWidth),
                    child: _buildPageImage(),
                  ),
                  ...widget.pdf.words.map(
                    (word) => _buildWord(context, word, pageWidth, pageHeight),
                  ),
                ],
              ),
            );

            // A viewport-sized child keeps the InteractiveViewer's pan
            // clamp well-defined (same letterbox trick as the manga
            // reader's fit-screen mode).
            return SizedBox(
              width: viewportWidth,
              height: viewportHeight,
              child: Center(child: pageContent),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPageImage() {
    final image = _pageImage;
    if (image != null) {
      return RawImage(image: image, fit: BoxFit.fill);
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
          ],
        ),
      );
    }
    if (_localPath == null) {
      final total = _total;
      String mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            total > 0
                ? CircularProgressIndicator(
                    value: _received <= 0 ? null : _received / total,
                  )
                : const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              total > 0
                  ? 'Downloading PDF... (${mb(_received)} / ${mb(total)} MB)'
                  : 'Downloading PDF...',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
          ],
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  /// Requests the render for the current page when nothing valid is
  /// displayed yet.  Runs post-frame: the render needs [_localPath] and
  /// the viewport width, and the widget rebuilds on every progress tick
  /// while downloading.
  void _scheduleRenderIfNeeded(BuildContext context, double viewportWidth) {
    if (_renderScheduled) return;
    final pixelWidth = _targetPixelWidth(context, viewportWidth);
    if (_pageImage != null &&
        _renderedPage == widget.pdf.pageNum &&
        _renderedWidth == pixelWidth) {
      return;
    }
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _localPath == null) {
        _renderScheduled = false;
        return;
      }
      _renderPage(widget.pdf.pageNum, pixelWidth);
    });
  }

  /// Render resolution follows the viewport (fit width) times the device
  /// pixel ratio, capped so a tablet cannot allocate absurd bitmaps.
  int _targetPixelWidth(BuildContext context, double viewportWidth) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (viewportWidth * dpr).clamp(600, 2048).round();
  }

  /// One word box: a Row of token cells, each sized by its character
  /// count (the web template's `flex: {{ char_lens[i] }} 1 0px`), with the
  /// fixed translucent status tint.  Known words get no tint but stay
  /// tappable.
  ///
  /// Only tap and long-press are wired, matching what
  /// TextDisplay.buildInteractiveWord actually wires for the manga
  /// overlay; the printed glyphs belong to the page image, so the cells
  /// paint color only.
  Widget _buildWord(
    BuildContext context,
    PdfWord word,
    double pageWidth,
    double pageHeight,
  ) {
    return Positioned(
      left: pageWidth * word.left / 100.0,
      top: pageHeight * word.top / 100.0,
      width: pageWidth * word.width / 100.0,
      height: pageHeight * word.height / 100.0,
      child: Row(
        children: [
          for (final item in word.items)
            Expanded(
              flex: item.text.isEmpty ? 1 : item.text.length,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onTap?.call(item, context),
                onLongPress: widget.onLongPress == null
                    ? null
                    : () => widget.onLongPress!(item),
                child: ColoredBox(
                  color: _statusTint(item.statusClass) ?? Colors.transparent,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The web PDF reader's fixed translucent pastels (styles.css): the
  /// tint must let the printed glyphs underneath show through, so theme
  /// status colors (opaque text backgrounds) would hide the page text.
  Color? _statusTint(String statusClass) {
    switch (RegExp(r'status(\d+)').firstMatch(statusClass)?.group(1)) {
      case '0':
        return const Color.fromRGBO(213, 255, 255, 0.42);
      case '1':
        return const Color.fromRGBO(245, 184, 169, 0.42);
      case '2':
        return const Color.fromRGBO(245, 204, 169, 0.42);
      case '3':
        return const Color.fromRGBO(245, 225, 169, 0.42);
      case '4':
        return const Color.fromRGBO(245, 243, 169, 0.42);
      case '5':
        return const Color.fromRGBO(221, 255, 221, 0.42);
      default:
        return null;
    }
  }
}
