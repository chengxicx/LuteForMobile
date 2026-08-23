import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/manga_page.dart';
import '../models/text_item.dart';
import 'text_display.dart';

/// Renders one Mokuro manga page: the page image with the OCR text
/// blocks overlaid, so each word is tappable for term lookup (the same
/// interaction as the regular text reader).
///
/// The blocks use percent coordinates of the page image, and the font
/// size is in cqw (1% of the rendered page width), matching the web
/// template.  Pinch to zoom; pan when zoomed in.
class MangaPageView extends StatefulWidget {
  final MangaPageData manga;
  final String imageUrl;
  final Map<String, String>? imageHeaders;
  final void Function(TextItem, BuildContext)? onTap;
  final void Function(TextItem)? onDoubleTap;
  final void Function(TextItem)? onLongPress;
  final void Function(TextItem)? onTripleTap;
  final String fontFamily;
  final FontWeight fontWeight;
  final bool isItalic;
  final Widget? bottomControlWidget;

  const MangaPageView({
    super.key,
    required this.manga,
    required this.imageUrl,
    this.imageHeaders,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onTripleTap,
    this.fontFamily = 'Roboto',
    this.fontWeight = FontWeight.normal,
    this.isItalic = false,
    this.bottomControlWidget,
  });

  @override
  State<MangaPageView> createState() => _MangaPageViewState();
}

class _MangaPageViewState extends State<MangaPageView> {
  bool _showText = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: Icon(_showText ? Icons.visibility : Icons.visibility_off),
                onPressed: () {
                  setState(() {
                    _showText = !_showText;
                  });
                },
                tooltip: _showText ? 'Hide text overlays' : 'Show text overlays',
                color: context.audioPlayerIcon,
                iconSize: 22,
                padding: EdgeInsets.all(4),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Page ${widget.manga.pageNum}  ·  pinch to zoom',
                  style: TextStyle(
                    color: context.appColorScheme.text.secondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 5.0,
            child: SingleChildScrollView(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final pageWidth = constraints.maxWidth;
                  final pageHeight =
                      pageWidth * widget.manga.imgHeight / widget.manga.imgWidth;
                  return SizedBox(
                    width: pageWidth,
                    height: pageHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          widget.imageUrl,
                          headers: widget.imageHeaders,
                          fit: BoxFit.fill,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.broken_image,
                                      size: 48, color: Colors.grey),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Failed to load manga image',
                                    style: TextStyle(
                                      color: context.appColorScheme.text
                                          .secondary,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        if (_showText)
                          ...widget.manga.blocks.map(
                            (block) => _buildBlock(context, block, pageWidth),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (widget.bottomControlWidget != null)
          widget.bottomControlWidget!,
      ],
    );
  }

  Widget _buildBlock(
    BuildContext context,
    MangaBlock block,
    double pageWidth,
  ) {
    final fontSize = pageWidth * block.fontSizeCqw / 100.0;

    // Build one tappable word widget for a text item.
    Widget word(TextItem item) {
      return TextDisplay.buildInteractiveWord(
        context,
        item,
        textSize: fontSize,
        lineSpacing: 1.1,
        fontFamily: widget.fontFamily,
        fontWeight: widget.fontWeight,
        isItalic: widget.isItalic,
        widgetKey: ValueKey(
          'manga-${item.paragraphId}-${item.order}-${item.wordId}',
        ),
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        onTripleTap: widget.onTripleTap,
      );
    }

    // A horizontal line: words wrapped left-to-right on a white backdrop.
    Widget horizontalLine(List<TextItem> lineItems) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Wrap(
          spacing: 0,
          runSpacing: 0,
          children: lineItems.map(word).toList(),
        ),
      );
    }

    // Vertical manga reproduces the CSS `writing-mode: vertical-rl` of the
    // web template: each log "line" becomes a vertical column (words stacked
    // top-to-bottom) and the columns flow right-to-left.  Rotating the whole
    // line (RotatedBox) would tilt every character sideways, so instead we
    // stack the words upright.
    List<Widget> lines;
    if (block.vertical) {
      lines = block.lineItems.map((lineItems) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: lineItems.map(word).toList(),
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

    return Positioned(
      left: pageWidth * block.left / 100.0,
      top: pageWidth * block.top * widget.manga.imgHeight /
          widget.manga.imgWidth /
          100.0,
      width: pageWidth * block.width / 100.0,
      height: pageWidth * block.height * widget.manga.imgHeight /
          widget.manga.imgWidth /
          100.0,
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
    );
  }
}
