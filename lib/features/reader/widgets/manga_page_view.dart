import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/manga_page.dart';
import '../models/text_item.dart';
import 'page_turn_flick_listener.dart';
import 'text_display.dart';

/// Renders one Mokuro manga page: the page image with the OCR text
/// blocks overlaid, so each word is tappable for term lookup (the same
/// interaction as the regular text reader).
///
/// The blocks use percent coordinates of the page image, and the font
/// size is in cqw (1% of the rendered page width), matching the web
/// template.  Like the web (and mokuro itself), the boxes are hidden
/// until the reader taps one; [revealAll] (the app-bar eye icon)
/// reveals every box at once.  A revealed box paints an opaque white
/// slab over the whole OCR box so the original art text underneath does
/// not bleed through.
///
/// Page turning mirrors the text reader: tap the right third of the art
/// for the next page, the left third for the previous one (a tap only
/// turns the page when no box is pinned -- the first tap outside a
/// pinned box just unpins it), a horizontal flick turns the page, and
/// the reader's hardware-key handler feeds the same [onTurnPage].
/// Pinch to zoom; pan when zoomed in.
///
/// [fitToScreen] switches the 1x layout between the two display modes
/// (the app-bar fit button toggles it):
///  - false: fit width -- the page fills the viewport width and pans
///    vertically, one screenful at a time (the classic mokuro scroll).
///  - true: fit screen -- the whole page is scaled to fit the viewport
///    (contain) and centered, so nothing is ever cut off (the web
///    reader's default fit; the letterbox belongs to the viewer).
/// While zoomed in, a horizontal flick only turns the page when the
/// view already sits at the horizontal pan boundary in the swipe
/// direction; elsewhere the flick pans, as in every manga reader.
class MangaPageView extends StatefulWidget {
  final MangaPageData manga;
  final String imageUrl;
  final Map<String, String>? imageHeaders;
  final bool revealAll;
  final bool fitToScreen;
  final void Function(bool forward)? onTurnPage;
  final void Function(TextItem, BuildContext)? onTap;
  final void Function(TextItem)? onDoubleTap;
  final void Function(TextItem)? onLongPress;
  final void Function(TextItem)? onTripleTap;
  final String fontFamily;
  final FontWeight fontWeight;
  final bool isItalic;

  const MangaPageView({
    super.key,
    required this.manga,
    required this.imageUrl,
    this.imageHeaders,
    this.revealAll = false,
    this.fitToScreen = false,
    this.onTurnPage,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onTripleTap,
    this.fontFamily = 'Roboto',
    this.fontWeight = FontWeight.normal,
    this.isItalic = false,
  });

  @override
  State<MangaPageView> createState() => _MangaPageViewState();
}

class _MangaPageViewState extends State<MangaPageView> {
  /// The single box revealed by tapping it -- the web's pinned
  /// `.hovered` block.  Tapping the page image again unpins it.
  int? _pinnedBlock;

  final TransformationController _transformation = TransformationController();

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MangaPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Page turn: the pinned box belonged to the previous page.
    if (!identical(widget.manga, oldWidget.manga)) _pinnedBlock = null;
    // Eye off hides everything, including a pinned box.
    if (!widget.revealAll && oldWidget.revealAll) _pinnedBlock = null;
    // Switching display mode resizes the page; a transform tuned for the
    // old geometry (pan offset, zoom) has no meaning in the new one.
    if (widget.fitToScreen != oldWidget.fitToScreen) {
      _transformation.value = Matrix4.identity();
    }
  }

  /// A tap on the art (outside every box): unpin first, then page-turn
  /// tap zones.  While zoomed in the visible area may sit inside any
  /// zone and taps are for reading, so zones are skipped.
  void _handleTapOnArt(Offset local, double pageWidth) {
    if (_pinnedBlock != null) {
      setState(() => _pinnedBlock = null);
      return;
    }
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
    // constrained:false lets the page be taller than the viewport: at 1x
    // the viewer pans vertically, a pinch zooms, and a zoomed pan moves
    // freely -- the mokuro reading mechanics, without a ScrollView.  The
    // flick page-turn machine lives in [PageTurnFlickListener], shared
    // with the PDF page view.
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final viewportHeight = constraints.maxHeight;
        final imgWidth = widget.manga.imgWidth;
        final imgHeight = widget.manga.imgHeight;

        // Fit-screen mode scales the whole page into the viewport
        // (contain); fit width fills the width and pans vertically.
        // The letterbox in fit-screen mode lives inside a
        // viewport-sized child, so the InteractiveViewer always sees
        // a child at least as large as itself and its pan clamp stays
        // well-defined in both modes.
        double pageWidth = viewportWidth;
        if (widget.fitToScreen &&
            imgWidth > 0 &&
            imgHeight > 0 &&
            viewportHeight.isFinite &&
            viewportHeight > 0) {
          final fitScale = math.min(
            viewportWidth / imgWidth,
            viewportHeight / imgHeight,
          );
          pageWidth = imgWidth * fitScale;
        }
        final pageWidthForLayout = pageWidth;
        final pageHeight = pageWidthForLayout * imgHeight / imgWidth;

        final pageContent = SizedBox(
          width: pageWidthForLayout,
          height: pageHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                // Tapping the art: unpin / page-turn tap zones.  Opaque:
                // the tap must register even where the image (or its
                // loading/error placeholder) has no hit-testable child
                // of its own.
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) =>
                    _handleTapOnArt(details.localPosition, pageWidthForLayout),
                // CachedNetworkImage, not Image.network: page images are
                // big, so without a disk cache every eviction (a few page
                // turns, or an app restart) re-downloads the same JPG.
                // Shares the disk cache with the next-page prefetcher.
                child: CachedNetworkImage(
                  imageUrl: widget.imageUrl,
                  httpHeaders: widget.imageHeaders,
                  fit: BoxFit.fill,
                  progressIndicatorBuilder: (context, url, progress) {
                    return const Center(child: CircularProgressIndicator());
                  },
                  errorWidget: (context, url, error) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.broken_image,
                            size: 48,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Failed to load manga image',
                            style: TextStyle(
                              color: context.appColorScheme.text.secondary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              ...widget.manga.blocks.asMap().entries.map(
                (entry) => _buildBlock(
                  context,
                  entry.key,
                  entry.value,
                  pageWidthForLayout,
                ),
              ),
            ],
          ),
        );

        return PageTurnFlickListener(
          transformation: _transformation,
          onTurnPage: widget.onTurnPage,
          child: InteractiveViewer(
            constrained: false,
            panEnabled: true,
            minScale: 1.0,
            maxScale: 5.0,
            transformationController: _transformation,
            child: widget.fitToScreen
                ? SizedBox(
                    width: viewportWidth,
                    height: viewportHeight,
                    child: Center(child: pageContent),
                  )
                : pageContent,
          ),
        );
      },
    );
  }

  Widget _buildBlock(
    BuildContext context,
    int index,
    MangaBlock block,
    double pageWidth,
  ) {
    final fontSize = pageWidth * block.fontSizeCqw / 100.0;
    final revealed = widget.revealAll || _pinnedBlock == index;

    // Build one tappable word widget for a text item.  [displayOverride]
    // renders a single character of the word in vertical blocks; taps and
    // highlights still carry the whole word.  [charIndex] keeps the widget
    // keys of a split word unique (its cells are siblings in one column).
    Widget word(TextItem item, {String? displayOverride, int? charIndex}) {
      return TextDisplay.buildInteractiveWord(
        context,
        item,
        displayOverride: displayOverride,
        textSize: fontSize,
        lineSpacing: block.vertical ? 1.0 : 1.1,
        fontFamily: widget.fontFamily,
        fontWeight: widget.fontWeight,
        isItalic: widget.isItalic,
        widgetKey: ValueKey(
          'manga-${item.paragraphId}-${item.order}-${item.wordId}'
          '${charIndex == null ? '' : '-c$charIndex'}',
        ),
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        onTripleTap: widget.onTripleTap,
      );
    }

    // A horizontal line: words wrapped left-to-right.  The white backdrop
    // lives on the whole block (one opaque slab over the OCR box), so the
    // lines only contribute their padding.
    Widget horizontalLine(List<TextItem> lineItems) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Wrap(
          spacing: 0,
          runSpacing: 0,
          children: lineItems.map(word).toList(),
        ),
      );
    }

    // Vertical manga reproduces the CSS `writing-mode: vertical-rl` of the
    // web template: each log "line" is one column, one character wide, with
    // the characters upright and stacked top-to-bottom, and the columns
    // flowing right-to-left.  The column must be built character by
    // character -- stacking whole words upright laid e.g. ちょっと out as a
    // horizontal run several characters wide, overflowing the OCR box and
    // covering the surrounding art.  Rotating the line (RotatedBox) is not
    // an option either: it would tilt every character sideways.
    List<Widget> lines;
    if (block.vertical) {
      lines = block.lineItems.map((lineItems) {
        final cells = <Widget>[];
        var charIndex = 0;
        for (final item in lineItems) {
          for (final rune in item.displayText.runes) {
            cells.add(
              word(
                item,
                displayOverride: String.fromCharCode(rune),
                charIndex: charIndex++,
              ),
            );
          }
        }
        if (cells.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: cells,
          ),
        );
      }).toList();
    } else {
      lines = block.lineItems.map(horizontalLine).toList();
    }

    final blockContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );

    // The web template paints a solid, opaque backdrop over the whole OCR
    // box when a block is revealed, so the original art text underneath is
    // fully hidden ("Without this the shrink-to-fit line backdrop can
    // leave parts of the image text visible").  A hidden block stays in
    // the tree as an invisible hit area: tapping it reveals the text,
    // exactly like clicking a mokuro box.
    return Positioned(
      left: pageWidth * block.left / 100.0,
      top:
          pageWidth *
          block.top *
          widget.manga.imgHeight /
          widget.manga.imgWidth /
          100.0,
      width: pageWidth * block.width / 100.0,
      height:
          pageWidth *
          block.height *
          widget.manga.imgHeight /
          widget.manga.imgWidth /
          100.0,
      child: GestureDetector(
        key: ValueKey('manga-block-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_pinnedBlock == index) return;
          setState(() => _pinnedBlock = index);
        },
        child: revealed
            ? Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: block.vertical
                    ? Directionality(
                        textDirection: TextDirection.rtl,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: lines,
                        ),
                      )
                    : blockContent,
              )
            : const SizedBox.expand(),
      ),
    );
  }
}
