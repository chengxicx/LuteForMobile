import 'text_item.dart';

/// One tokenized word overlaid on a PDF page.
///
/// Coordinates are in percent of the page (mirroring the web template,
/// which positions word boxes with `left/top/width/height` in %).  The
/// boxes are estimated by the server from pypdf geometry; the web reader
/// refines them against pdf.js after rendering, but they are usable as
/// served.
class PdfWord {
  final double left;
  final double top;
  final double width;
  final double height;

  /// The tokens of this word, in reading order.  The printed glyphs live
  /// in the rendered page image underneath, so the tokens are only
  /// tappable tint cells: on the web each gets a flex slot sized by its
  /// character count so the cells together cover the word box, and the
  /// client renders the same distribution.
  final List<TextItem> items;

  const PdfWord({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.items = const [],
  });
}

/// Parsed data for one PDF book page: the PDF file plus the tokenized
/// words that overlay it.
class PdfPageData {
  /// Server-relative path of the whole PDF file, e.g.
  /// `/static/<pdf_path>` -- one file for the whole book, rendered page
  /// by page on the client.
  final String pdfPath;
  final double pageWidth;
  final double pageHeight;
  final int pageNum;
  final List<PdfWord> words;

  const PdfPageData({
    required this.pdfPath,
    required this.pageWidth,
    required this.pageHeight,
    required this.pageNum,
    this.words = const [],
  });
}
