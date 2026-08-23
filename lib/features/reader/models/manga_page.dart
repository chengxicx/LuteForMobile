import 'text_item.dart';

/// One Mokuro manga text block overlaid on the page image.
///
/// Coordinates are in percent of the page image (mirroring the web
/// template, which positions blocks with `left/top/width/height` in %).
/// [fontSizeCqw] is the block font size in container-query width units
/// (1cqw = 1% of the rendered page width), matching the web CSS.
class MangaBlock {
  final double left;
  final double top;
  final double width;
  final double height;
  final bool vertical;
  final double fontSizeCqw;
  final List<List<TextItem>> lineItems;

  const MangaBlock({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.vertical = false,
    this.fontSizeCqw = 0,
    this.lineItems = const [],
  });
}

/// Parsed data for one manga (Mokuro) page: the page image plus the
/// text blocks that overlay it.
class MangaPageData {
  /// Server-relative image path, e.g. `/static/<manga_path>/page1.jpg`.
  final String imagePath;
  final double imgWidth;
  final double imgHeight;
  final int pageNum;
  final List<MangaBlock> blocks;

  const MangaPageData({
    required this.imagePath,
    required this.imgWidth,
    required this.imgHeight,
    required this.pageNum,
    this.blocks = const [],
  });
}
