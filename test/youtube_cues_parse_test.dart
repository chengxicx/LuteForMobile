// Contract tests for the YouTube book's subtitle cues.
//
// The mobile player decides "this sentence has finished" from the cue
// boundaries, and Loop / Auto-pause act on that.  The web player reads the
// same data from `LUTE_YT_DATA.cues` (the book's `BkSrtData`, a JSON array of
// `{start, end, text}` in seconds).  These tests pin:
//
//   * the cues actually reach `YoutubeData`;
//   * cue text is arbitrary book content -- brackets, braces, quotes, commas
//     and colons must not break the array scan;
//   * an unusable cue is dropped rather than defaulted, because a cue with no
//     end would read as "ends immediately" and looping it would spin;
//   * a missing or malformed block degrades to "no subtitles" instead of
//     taking the video down with it.
//
// It also pins the two pieces the *reading text* needs to mark the line being
// played, for every media book and not only YouTube: the cue list itself and
// the server's line -> cue map (`window.LUTE_PAGE_CUE_MAP`).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/core/network/html_parser.dart';
import 'package:lute_for_mobile/features/reader/models/page_data.dart';
import 'package:lute_for_mobile/features/reader/models/youtube_data.dart';

/// The page body is irrelevant here; only the metadata block is under test.
const String _textHtml = '<div id="thetext"></div>';

String _metadataHtml(String scriptBody) {
  return '''
<script type="text/javascript">
  window.LUTE_YT_DATA = window.LUTE_YT_DATA || {};
$scriptBody
</script>
''';
}

/// A metadata block shaped like the web player include
/// (`lute/templates/read/youtube_player.html`).
///
/// The video id is passed as a ready JS literal because the include renders it
/// through `| tojson`, so a real page carries `"dQw4w9WgXcQ"` quoted (and
/// `null` for a non-video book).
String _youtubeBlock({
  String videoIdLiteral = '"dQw4w9WgXcQ"',
  String startPos = '0.5',
  String? cues,
}) {
  return '''
  window.LUTE_YT_DATA.videoId = $videoIdLiteral;
  window.LUTE_YT_DATA.audioUrl = null;
  window.LUTE_YT_DATA.cues = ${cues ?? '[]'};
  window.LUTE_YT_DATA.words = [];
  window.LUTE_YT_DATA.bookId = 7;
  window.LUTE_YT_DATA.startPos = $startPos;
''';
}

YoutubeData? _parse(String scriptBody) {
  final parser = HtmlParser();
  return parser
      .parsePage(_textHtml, _metadataHtml(scriptBody), bookId: 7)
      .youtube;
}

PageData _parsePage(String textHtml, String metadataHtml) {
  return HtmlParser().parsePage(textHtml, metadataHtml, bookId: 7);
}

void main() {
  test('cues are read out of the LUTE_YT_DATA block', () {
    final cues = jsonEncode([
      {'start': 1.5, 'end': 3.25, 'text': 'こんにちは'},
      {'start': 3.25, 'end': 5, 'text': 'さようなら'},
    ]);

    final data = _parse(_youtubeBlock(cues: cues));

    expect(data, isNotNull);
    expect(data!.videoId, 'dQw4w9WgXcQ');
    expect(data.startPos, 0.5);
    expect(data.hasCues, isTrue);
    expect(data.cues, hasLength(2));
    expect(data.cues.first.start, 1.5);
    expect(data.cues.first.end, 3.25);
    expect(data.cues.first.text, 'こんにちは');
    expect(data.cues.last.text, 'さようなら');
  });

  test('cue text may contain brackets, quotes, commas and colons', () {
    // Subtitle text is arbitrary book content.  A regex or a naive
    // `indexOf(']')` would cut the array short here.
    const awkward = 'a,] } "quoted" [b: c, d';
    final cues = jsonEncode([
      {'start': 0, 'end': 2, 'text': awkward},
      {'start': 2, 'end': 4, 'text': 'after the awkward one'},
    ]);

    final data = _parse(_youtubeBlock(cues: cues));

    expect(data, isNotNull);
    expect(data!.cues, hasLength(2));
    expect(data.cues.first.text, awkward);
    expect(
      data.cues.last.text,
      'after the awkward one',
      reason: 'the array must not have been closed early by a bracket in text',
    );
  });

  test('unusable cues are dropped, never defaulted to zero', () {
    final cues = jsonEncode([
      {'start': 1, 'end': 2, 'text': 'good'},
      {'start': 3, 'text': 'no end'},
      {'end': 4, 'text': 'no start'},
      'not an object',
      {'start': 5, 'text': 'still no end'},
    ]);

    final data = _parse(_youtubeBlock(cues: cues));

    expect(data, isNotNull);
    expect(
      data!.cues.map((c) => c.text),
      ['good'],
      reason: 'a cue without both boundaries cannot drive loop or auto-pause',
    );
  });

  test('an end before the start is collapsed onto the start', () {
    final cues = jsonEncode([
      {'start': 4, 'end': 2, 'text': 'backwards'},
    ]);

    final data = _parse(_youtubeBlock(cues: cues));

    expect(data, isNotNull);
    expect(data!.cues.single.end, 4);
    expect(
      data.cues.single.end,
      greaterThanOrEqualTo(data.cues.single.start),
      reason: 'a negative-length cue would make the playhead look past its end',
    );
  });

  test('an unterminated array degrades to "no subtitles"', () {
    final data = _parse(_youtubeBlock(cues: '[{"start": 1, "end": 2'));

    expect(
      data,
      isNotNull,
      reason: 'the video must still be playable without its subtitles',
    );
    expect(data!.cues, isEmpty);
  });

  test('a block with no cues line still yields a playable video', () {
    // An older server, before cues were added to the include.
    final data = _parse('''
  window.LUTE_YT_DATA.videoId = "dQw4w9WgXcQ";
  window.LUTE_YT_DATA.audioUrl = null;
  window.LUTE_YT_DATA.bookId = 7;
  window.LUTE_YT_DATA.startPos = 12;
''');

    expect(data, isNotNull);
    expect(data!.cues, isEmpty);
    expect(data.hasCues, isFalse);
    expect(data.startPos, 12);
  });

  test('a non-video book exposes no youtube data', () {
    // MP3 and plain-text books reuse the same include with a null videoId.
    final data = _parse(_youtubeBlock(videoIdLiteral: 'null', cues: '[]'));

    expect(data, isNull);
  });

  test('string times are accepted', () {
    // Some servers stringify numbers rather than emitting bare JSON numbers.
    final cues = jsonEncode([
      {'start': '1.25', 'end': '2.5', 'text': 'textual times'},
    ]);

    final data = _parse(_youtubeBlock(cues: cues));

    expect(data!.cues.single.start, 1.25);
    expect(data.cues.single.end, 2.5);
  });

  // 媒体播放器在正文里标记「播到哪一行」靠两样东西：cue 列表（时间 → 句子）
  // 和行→cue 映射（句子的行 → cue 索引）。MP3 书与视频书共用同一个 include，
  // 所以两者都要在非 youtube 分支上也拿得到。
  group('媒体书共用的 cues 与行→cue 映射', () {
    test('MP3 书（videoId 为 null）也能拿到 cues', () {
      final cues = jsonEncode([
        {'start': 0, 'end': 1.5, 'text': '第一句'},
      ]);
      final page = _parsePage(
        _textHtml,
        _metadataHtml('''
  window.LUTE_YT_DATA.videoId = null;
  window.LUTE_YT_DATA.audioUrl = "/useraudio/stream/7";
  window.LUTE_YT_DATA.cues = $cues;
  window.LUTE_YT_DATA.bookId = 7;
'''),
      );

      expect(page.youtube, isNull, reason: 'MP3 书没有视频');
      expect(page.cues, hasLength(1));
      expect(page.cues.single.text, '第一句');
      expect(page.cues.single.end, 1.5);
    });

    test('行→cue 映射从页面正文里解析出来', () {
      final page = _parsePage(
        '''
<script type="text/javascript">
  window.LUTE_PAGE_CUE_MAP = [4, 5, 5, 6];
</script>
<div id="thetext"></div>
''',
        _metadataHtml(_youtubeBlock()),
      );

      expect(
        page.pageCueMap,
        [4, 5, 5, 6],
        reason: '多行字幕：两行可以指向同一个 cue',
      );
    });

    test('没有映射块时为空，而不是崩掉或猜一个', () {
      // 旧服务端不渲染 LUTE_PAGE_CUE_MAP；调用方会回退到按 cue 文本匹配。
      final page = _parsePage(_textHtml, _metadataHtml(_youtubeBlock()));

      expect(page.pageCueMap, isEmpty);
    });
  });
}
