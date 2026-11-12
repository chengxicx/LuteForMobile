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
    // several lines.  The comparison is tolerant (see [textsMatch]): the two
    // texts are typed in separately, and one stray character in the page
    // must not cost the line its highlight.
    if (pageCueMap.length == lines.length) {
      final hits = <_PageLine>[];
      for (var k = 0; k < lines.length; k++) {
        if (pageCueMap[k] == cueIndex) hits.add(lines[k]);
      }
      if (hits.isNotEmpty) {
        final joined = hits.map((line) => line.text).join();
        if (textsMatch(joined, want)) {
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

  /// 两段文本是不是"同一行"，容忍个别字的出入。
  ///
  /// 页面正文与字幕是两份**独立录入**的文本：歌词是人手打的，课文可能是
  /// OCR 稿，差一个标点、一个假名、甚至多打一个字都很常见。真实例子：
  /// book 1143「サヨナラ」的第二句正文写成「違う風に君を愛したの**かか**な?」，
  /// SRT 是「…のかな?」。逐字比对于是失败 → 位置映射被判"不可信" → 整行
  /// 从头到尾都没有高亮（前后两句都正常，用户看到的就是"播到第二句高亮
  /// 没了，第三句才恢复"）。
  ///
  /// 位置映射是服务端按行号算出来的，行号对得上就足以说明这一行是这条
  /// 字幕；个别字的出入不该让整行失去高亮。但也不能烂容：整行被删掉、
  /// 页面被重排这类真正"对不上"的情况，两行文本会完全不同，相似度掉到
  /// 很低，仍然判不可信（见 `test/playing_line_test.dart` 的"改过的正文"）。
  ///
  /// 相似度用二元组 Dice 系数：对换位/插入很稳，实现只有十几行，且不必
  /// 关心编辑距离的边界细节。阈值 0.8 对应"每行 20% 以内差异"。
  static bool textsMatch(String a, String b) {
    final x = _norm(a);
    final y = _norm(b);
    if (x == y) return true;
    if (x.isEmpty || y.isEmpty) return false;
    // 长度差到一半以上就不可能是同一行（多打一个字远到不了）。
    final shorter = x.length < y.length ? x.length : y.length;
    final longer = x.length < y.length ? y.length : x.length;
    if (shorter * 2 < longer) return false;
    return _dice(x, y) >= 0.8;
  }

  /// 二元组 Dice 系数，[0, 1]。
  static double _dice(String a, String b) {
    final left = _bigrams(a);
    final right = _bigrams(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final remaining = <String, int>{};
    for (final gram in right) {
      remaining[gram] = (remaining[gram] ?? 0) + 1;
    }
    var overlap = 0;
    for (final gram in left) {
      final count = remaining[gram] ?? 0;
      if (count > 0) {
        overlap++;
        remaining[gram] = count - 1;
      }
    }
    return 2 * overlap / (left.length + right.length);
  }

  static List<String> _bigrams(String text) {
    if (text.length < 2) return [text];
    return [for (var i = 0; i + 1 < text.length; i++) text.substring(i, i + 2)];
  }
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
