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
  final Duration? audioCurrentPos;
  final List<double> audioBookmarks;
  final MangaPageData? mangaPage;
  final YoutubeData? youtube;

  PageData({
    required this.bookId,
    required this.currentPage,
    required this.pageCount,
    this.title,
    required this.paragraphs,
    this.audioFilename,
    this.audioCurrentPos,
    this.audioBookmarks = const [],
    this.mangaPage,
    this.youtube,
  });

  bool get hasAudio => audioFilename != null && audioFilename!.isNotEmpty;

  bool get isManga => mangaPage != null;

  bool get isYoutube => youtube != null;

  PageData copyWith({
    int? bookId,
    int? currentPage,
    int? pageCount,
    String? title,
    List<Paragraph>? paragraphs,
    String? audioFilename,
    Duration? audioCurrentPos,
    List<double>? audioBookmarks,
    MangaPageData? mangaPage,
    YoutubeData? youtube,
  }) {
    return PageData(
      bookId: bookId ?? this.bookId,
      currentPage: currentPage ?? this.currentPage,
      pageCount: pageCount ?? this.pageCount,
      title: title ?? this.title,
      paragraphs: paragraphs ?? this.paragraphs,
      audioFilename: audioFilename ?? this.audioFilename,
      audioCurrentPos: audioCurrentPos ?? this.audioCurrentPos,
      audioBookmarks: audioBookmarks ?? this.audioBookmarks,
      mangaPage: mangaPage ?? this.mangaPage,
      youtube: youtube ?? this.youtube,
    );
  }

  String get pageIndicator => '$currentPage/$pageCount';
}
