/// Parsed data for one reader-mode EPUB chapter page.
///
/// The chapter itself is NOT rendered natively: [EpubChapterView] loads
/// `/read/epub_render/<bookId>/<page>` in a WebView, where the server
/// page mounts the word spans exactly like the web reader.  What the
/// app needs locally is only
///
///  * the chapter's presence (this object being non-null switches the
///    reader over to the WebView), and
///  * the word tokens (`PageData.paragraphs`, built from the same
///    `#lute-epub-tokens` JSON), so every native feature that reads
///    page data -- word counts, rest-known, status overlays, the
///    term-card lookup by word id -- keeps working unchanged.
///
/// The stylesheet URLs are carried for diagnostics / future use; the
/// render page loads them itself.
class EpubChapterData {
  /// Server-relative theme-following stylesheet (`lute.css`).
  final String cssUrl;

  /// Server-relative keep-colours stylesheet (`lute-orig.css`).
  final String origCssUrl;

  /// True when the chapter declares a fixed pixel viewport
  /// (`.epub-body[data-epub-viewport]`, e.g. a picture book): the
  /// render page fits it like a PDF page and the app offers zoom
  /// buttons.
  final bool fixedLayout;

  /// The declared viewport in px, when [fixedLayout] is true.
  final double? viewportWidth;
  final double? viewportHeight;

  const EpubChapterData({
    required this.cssUrl,
    required this.origCssUrl,
    this.fixedLayout = false,
    this.viewportWidth,
    this.viewportHeight,
  });
}
