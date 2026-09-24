import 'paragraph.dart';
import 'manga_page.dart';
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
  final List<double> audioBookmarks;
  final MangaPageData? mangaPage;
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

  PageData({
    required this.bookId,
    required this.currentPage,
    required this.pageCount,
    this.title,
    required this.paragraphs,
    this.audioFilename,
    this.audioUrl,
    this.audioCurrentPos,
    this.audioBookmarks = const [],
    this.mangaPage,
    this.youtube,
    this.bilibili,
    this.cues = const [],
    this.pageCueMap = const [],
  });

  /// A book has playable audio when it has an uploaded audio file
  /// (regular audio books set `book_audio_file`) or when the page metadata
  /// provides an audio URL (MP3 books expose `LUTE_YT_DATA.audioUrl` even
  /// though `book_audio_file` is left empty).
  bool get hasAudio =>
      (audioFilename != null && audioFilename!.isNotEmpty) ||
      (audioUrl != null && audioUrl!.isNotEmpty);

  bool get isManga => mangaPage != null;

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
    YoutubeData? youtube,
    BilibiliData? bilibili,
    List<YoutubeCue>? cues,
    List<int>? pageCueMap,
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
      youtube: youtube ?? this.youtube,
      bilibili: bilibili ?? this.bilibili,
      cues: cues ?? this.cues,
      pageCueMap: pageCueMap ?? this.pageCueMap,
    );
  }

  String get pageIndicator => '$currentPage/$pageCount';
}
