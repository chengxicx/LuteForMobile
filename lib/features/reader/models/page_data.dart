import 'epub_chapter.dart';
import 'paragraph.dart';
import 'manga_page.dart';
import 'pdf_page.dart';
import 'youtube_data.dart';

class PageData {
  final int bookId;
  final int currentPage;
  final int pageCount;
  final String? title;
  final List<Paragraph> paragraphs;
  final String? audioFilename;
  final String? audioUrl;
  final Duration? audioCurrentPos;

  /// Audio bookmarks in seconds, or null when the page carried none.
  ///
  /// **null and `[]` are not interchangeable.** `[]` means the server says
  /// this book has no bookmarks; null means the page never told us.  The
  /// player must only write back a list it actually loaded -- posting an
  /// empty one over the stored value is what wiped every bookmark in the
  /// library (see `_extractAudioBookmarks`).
  final List<double>? audioBookmarks;
  final MangaPageData? mangaPage;
  final PdfPageData? pdfPage;
  final EpubChapterData? epubChapter;
  final YoutubeData? youtube;
  final BilibiliData? bilibili;

  /// Subtitle cues of a media book, in playback order.
  ///
  /// Shared by every player that reads from cues -- MP3 (and the other
  /// audio-backed media books), YouTube and Bilibili -- because the server
  /// emits the same `LUTE_YT_DATA.cues` block for all of them.  Empty for
  /// books without subtitles, and for plain text books.
  final List<YoutubeCue> cues;

  /// Cue index of each line of this page, in line order
  /// (`window.LUTE_PAGE_CUE_MAP`, rendered by `read/page_content.html`).
  ///
  /// A media book's text is its cue texts joined by newlines, so one page
  /// line is one cue; this is the page's slice of the cue lines.  Empty for
  /// books without cues, and for pages whose lines no longer line up with
  /// the cues (the page text can be hand-edited).
  final List<int> pageCueMap;

  /// The language whose readings annotate this page as furigana
  /// (`LUTE_FURIGANA.langId`, rendered by `read/index.html`).
  ///
  /// This is the `language_id` the readings endpoint wants.  It is null on
  /// servers predating the block, which is also the signal to leave the
  /// page layout untouched -- no reading slot is reserved, so a page from
  /// an older server looks exactly as it did before.
  ///
  /// Note the app does **not** read the block's `enabled` flag: the reader
  /// has its own "show furigana" setting, independent of the language's
  /// web toggle.
  final int? furiganaLangId;

  /// Which words on this page get a reading (`LUTE_FURIGANA.script`,
  /// rendered by `read/index.html`): "thai" annotates every Thai word,
  /// "han" only Han-bearing ones.
  ///
  /// Null on servers predating the field -- and every value but "thai"
  /// selects the "han" rule, the same fallback the web reader applies
  /// (`lute-furigana.js`: `needs_reading`).
  final String? furiganaScript;

  /// The book set (series) this book belongs to, as the server names it.
  ///
  /// An EPUB import writes **one Lute book per chapter**, and the chapters
  /// of one volume share a book tag that the server is configured to treat
  /// as a series (`book_series_tags`).  `read/index.html` renders the tag
  /// only for such a book -- as the "back to book set" link at the end of
  /// the text -- so its presence *is* the answer to "is this a chapter of
  /// something bigger".  Null for a standalone book.
  final String? seriesTag;

  /// The chapter books on either side of this one in that set.
  ///
  /// The server works these out itself (`lute/book/series.py:
  /// series_neighbours`) and writes them into the reading page as hidden
  /// inputs, so the client inherits the same order the web reader's
  /// end-of-book arrows use (non-archived first, then natural title
  /// order).  Null at the start / end of the set.
  final int? seriesPrevBookId;
  final int? seriesNextBookId;

  PageData({
    required this.bookId,
    required this.currentPage,
    required this.pageCount,
    this.title,
    required this.paragraphs,
    this.audioFilename,
    this.audioUrl,
    this.audioCurrentPos,
    this.audioBookmarks,
    this.mangaPage,
    this.pdfPage,
    this.epubChapter,
    this.youtube,
    this.bilibili,
    this.cues = const [],
    this.pageCueMap = const [],
    this.furiganaLangId,
    this.furiganaScript,
    this.seriesTag,
    this.seriesPrevBookId,
    this.seriesNextBookId,
  });

  /// A book has playable audio when it has an uploaded audio file
  /// (regular audio books set `book_audio_file`) or when the page metadata
  /// provides an audio URL (MP3 books expose `LUTE_YT_DATA.audioUrl` even
  /// though `book_audio_file` is left empty).
  bool get hasAudio =>
      (audioFilename != null && audioFilename!.isNotEmpty) ||
      (audioUrl != null && audioUrl!.isNotEmpty);

  bool get isManga => mangaPage != null;

  bool get isPdf => pdfPage != null;

  bool get isEpub => epubChapter != null;

  bool get isYoutube => youtube != null;

  bool get isBilibili => bilibili != null;

  /// A page whose top player is an online video (YouTube or Bilibili),
  /// as opposed to a plain text / audio / manga page.
  bool get isVideoBook => youtube != null || bilibili != null;

  PageData copyWith({
    int? bookId,
    int? currentPage,
    int? pageCount,
    String? title,
    List<Paragraph>? paragraphs,
    String? audioFilename,
    String? audioUrl,
    Duration? audioCurrentPos,
    List<double>? audioBookmarks,
    MangaPageData? mangaPage,
    PdfPageData? pdfPage,
    EpubChapterData? epubChapter,
    YoutubeData? youtube,
    BilibiliData? bilibili,
    List<YoutubeCue>? cues,
    List<int>? pageCueMap,
    int? furiganaLangId,
    String? furiganaScript,
    String? seriesTag,
    int? seriesPrevBookId,
    int? seriesNextBookId,
  }) {
    return PageData(
      bookId: bookId ?? this.bookId,
      currentPage: currentPage ?? this.currentPage,
      pageCount: pageCount ?? this.pageCount,
      title: title ?? this.title,
      paragraphs: paragraphs ?? this.paragraphs,
      audioFilename: audioFilename ?? this.audioFilename,
      audioUrl: audioUrl ?? this.audioUrl,
      audioCurrentPos: audioCurrentPos ?? this.audioCurrentPos,
      audioBookmarks: audioBookmarks ?? this.audioBookmarks,
      mangaPage: mangaPage ?? this.mangaPage,
      pdfPage: pdfPage ?? this.pdfPage,
      epubChapter: epubChapter ?? this.epubChapter,
      youtube: youtube ?? this.youtube,
      bilibili: bilibili ?? this.bilibili,
      cues: cues ?? this.cues,
      pageCueMap: pageCueMap ?? this.pageCueMap,
      furiganaLangId: furiganaLangId ?? this.furiganaLangId,
      furiganaScript: furiganaScript ?? this.furiganaScript,
      seriesTag: seriesTag ?? this.seriesTag,
      seriesPrevBookId: seriesPrevBookId ?? this.seriesPrevBookId,
      seriesNextBookId: seriesNextBookId ?? this.seriesNextBookId,
    );
  }

  String get pageIndicator => '$currentPage/$pageCount';
}
