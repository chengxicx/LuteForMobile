import '../models/paragraph.dart';
import '../models/youtube_data.dart';

/// Works out which sentence(s) of the page the player is on, so the reading
/// text itself can mark them.
///
/// Mirror of the web reader's `static/js/lute-playing-line.js`.  Two callers
/// there, the same split here:
///
///  * The media players (mp3 / youtube / bilibili / video) know the absolute
///    subtitle cue index and its text -- see [sentenceIdsForCue].  A media
///    book's text is its cue texts joined by newlines
///    (`parse_subtitle_content`), so one page *line* is one cue, and the
///    server hands over the cue index of each line as
///    `window.LUTE_PAGE_CUE_MAP`, which the parser reads into the page's
///    cue map.
///  * The TTS player builds its cues from the sentence spans themselves, so
///    it already knows the sentence id and never comes through here.
///
/// Everything is resolved per call rather than cached: the page is swapped on
/// every page turn, so a cached line list would belong to the previous page.
class PlayingLine {
  PlayingLine._();

  /// Sentence ids of the line holding cue [cueIndex], whose text is [cueText].
  ///
  /// Returns an empty set when that cue is not on this page -- the honest
  /// answer while the reader is somewhere else in the book, and the same one
  /// the web helper gives.
  static Set<int> sentenceIdsForCue({
    required List<Paragraph> paragraphs,
    required List<int> pageCueMap,
    required int cueIndex,
    required String cueText,
  }) {
    if (cueIndex < 0) return const {};

    final lines = _lines(paragraphs);
    if (lines.isEmpty) return const {};

    final want = _norm(cueText);

    // The server's map is positional (line k of the page -> cue map[k]), so
    // it is only trusted when the lines it names actually hold the cue's
    // text: the page text can be edited out of step with the cues, and
    // marking the wrong line is worse than marking none.  The hit lines are
    // compared joined, since one cue can be a multi-line subtitle and so own
    // several lines.
    if (pageCueMap.length == lines.length) {
      final hits = <_PageLine>[];
      for (var k = 0; k < lines.length; k++) {
        if (pageCueMap[k] == cueIndex) hits.add(lines[k]);
      }
      if (hits.isNotEmpty) {
        final joined = hits.map((line) => line.text).join();
        if (joined == want) {
          return hits.expand((line) => line.sentenceIds).toSet();
        }
      }
    }

    if (want.isEmpty) return const {};

    // No usable map (or it did not check out): match the cue text against the
    // page's lines.  Only the first match is marked, so a repeated line (a
    // chorus, say) does not light up everywhere.
    for (final line in lines) {
      if (line.text == want) return line.sentenceIds.toSet();
    }
    return const {};
  }

  /// Index of the cue covering [seconds], or -1 when the time falls outside
  /// every cue (before the first subtitle, or in a gap between two).  The
  /// same rule the media players use to decide which sentence is playing.
  static int cueIndexAt(List<YoutubeCue> cues, double seconds) {
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (seconds >= cue.start && seconds < cue.end) return i;
    }
    return -1;
  }

  /// The page's lines: a line is a run of consecutive sentences sharing a
  /// server paragraph number (`data-paragraph-id`).  The parser splits the
  /// page into one entry per `.textsentence` span, while a media book's line
  /// (one subtitle cue) can hold several of them.
  static List<_PageLine> _lines(List<Paragraph> paragraphs) {
    final lines = <_PageLine>[];
    int? currentParagraphId;
    var buffer = StringBuffer();
    var sentenceIds = <int>{};

    void flush() {
      if (sentenceIds.isEmpty) return;
      lines.add(
        _PageLine(text: _norm(buffer.toString()), sentenceIds: sentenceIds),
      );
    }

    for (final paragraph in paragraphs) {
      if (paragraph.textItems.isEmpty) continue;
      final paragraphId = paragraph.textItems.first.paragraphId;

      if (currentParagraphId != null && paragraphId != currentParagraphId) {
        flush();
        buffer = StringBuffer();
        sentenceIds = <int>{};
      }
      currentParagraphId = paragraphId;

      for (final item in paragraph.textItems) {
        buffer.write(item.text);
        sentenceIds.add(item.sentenceId);
      }
    }
    flush();

    return lines;
  }

  /// Compare on non-whitespace characters only: the renderer collapses runs
  /// of spaces, and the empty-paragraph sentinel it appends is a zero-width
  /// space, which `\s` does not match.
  static String _norm(String text) =>
      text.replaceAll(RegExp(r'[\s\u200b]+'), '');
}

class _PageLine {
  final String text;
  final Set<int> sentenceIds;

  const _PageLine({required this.text, required this.sentenceIds});
}

/// Convenience wrapper for a page: [PageData] is imported lazily by callers
/// to keep this file free of the network layer.
typedef PlayingLineCueResolver =
    Set<int> Function({required List<Paragraph> paragraphs});
