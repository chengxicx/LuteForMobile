// Contract tests for the Bilibili book's player data.
//
// `templates/read/bilibili_player.html` renders the same LUTE_YT_DATA block
// as the YouTube include, but with `bilibiliUrl` (the official embed URL,
// absolute) and `mpdUrl` (the server-relative DASH manifest) instead of
// `videoId`.  Before mobile parsed these fields a bilibili book exposed no
// player at all.  These tests pin:
//
//   * mpdUrl / bilibiliUrl / startPos / cues all reach `BilibiliData`;
//   * Flask's htmlsafe tojson escaping (`&` -> `\u0026`) is decoded;
//   * a null mpdUrl (server cannot relay the stream) still yields the
//     embed-only fallback data;
//   * a block with neither URL, and every non-bilibili page, yields null;
//   * the two extractors do not cross-talk: a bilibili block must look
//     like "no youtube" and vice versa.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/core/network/html_parser.dart';
import 'package:lute_for_mobile/features/reader/models/page_data.dart';

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

/// A metadata block shaped like `templates/read/bilibili_player.html`.
/// String values pass through Jinja `| tojson`, so they arrive quoted;
/// Flask's htmlsafe JSON escapes `&` as ` u0026` in the embed URL.
String _bilibiliBlock({
  String bilibiliUrlLiteral =
      '"https://player.bilibili.com/player.html?bvid=BV1A2b3c4d5e'
      '\\u0026page=1"',
  String mpdUrlLiteral =
      '"/read/bilibili/stream/mpd/BV1A2b3c4d5e?page=1"',
  String startPos = '12.5',
  String? cues,
}) {
  return '''
  window.LUTE_YT_DATA.bilibiliUrl = $bilibiliUrlLiteral;
  window.LUTE_YT_DATA.mpdUrl = $mpdUrlLiteral;
  window.LUTE_YT_DATA.audioUrl = null;
  window.LUTE_YT_DATA.cues = ${cues ?? '[]'};
  window.LUTE_YT_DATA.words = [];
  window.LUTE_YT_DATA.bookId = 7;
  window.LUTE_YT_DATA.startPos = $startPos;
''';
}

PageData _parse(String scriptBody) {
  final parser = HtmlParser();
  return parser.parsePage(_textHtml, _metadataHtml(scriptBody), bookId: 7);
}

void main() {
  test('mpdUrl, embed URL, startPos and cues reach BilibiliData', () {
    final cues = jsonEncode([
      {'start': 1.5, 'end': 3.25, 'text': '你好'},
      {'start': 3.25, 'end': 5, 'text': '再见'},
    ]);

    final page = _parse(_bilibiliBlock(cues: cues));

    final bili = page.bilibili;
    expect(bili, isNotNull);
    expect(
      bili!.mpdUrl,
      '/read/bilibili/stream/mpd/BV1A2b3c4d5e?page=1',
    );
    expect(
      bili.embedUrl,
      'https://player.bilibili.com/player.html?bvid=BV1A2b3c4d5e&page=1',
      reason: 'Flask htmlsafe tojson emits \\u0026, which must decode to &',
    );
    expect(bili.hasStream, isTrue);
    expect(bili.hasEmbed, isTrue);
    expect(bili.startPos, 12.5);
    expect(bili.cues, hasLength(2));
    expect(bili.cues.first.text, '你好');
  });

  test('a null mpdUrl degrades to embed-only data, not no player', () {
    final page = _parse(_bilibiliBlock(mpdUrlLiteral: 'null'));

    final bili = page.bilibili;
    expect(bili, isNotNull);
    expect(bili!.hasStream, isFalse);
    expect(bili.mpdUrl, isNull);
    expect(bili.hasEmbed, isTrue);
    expect(
      page.youtube,
      isNull,
      reason: 'the embed fallback must still surface a bilibili player',
    );
  });

  test('missing startPos / cues still yields a playable entry', () {
    final page = _parse('''
  window.LUTE_YT_DATA.bilibiliUrl = "https://player.bilibili.com/x";
  window.LUTE_YT_DATA.mpdUrl = "/read/bilibili/stream/mpd/BV1";
  window.LUTE_YT_DATA.bookId = 7;
''');

    final bili = page.bilibili;
    expect(bili, isNotNull);
    expect(bili!.startPos, 0);
    expect(bili.cues, isEmpty);
  });

  test('a block with neither URL is ignored', () {
    final page = _parse(_bilibiliBlock(
      bilibiliUrlLiteral: 'null',
      mpdUrlLiteral: 'null',
    ));

    expect(page.bilibili, isNull);
    expect(page.youtube, isNull);
  });

  test('cue text with brackets and quotes still parses', () {
    const awkward = 'a,] } "quoted" [b: c, d';
    final cues = jsonEncode([
      {'start': 0, 'end': 2, 'text': awkward},
      {'start': 2, 'end': 4, 'text': 'after'},
    ]);

    final page = _parse(_bilibiliBlock(cues: cues));

    expect(page.bilibili!.cues, hasLength(2));
    expect(page.bilibili!.cues.first.text, awkward);
  });

  test('a YouTube block is not misread as bilibili (and vice versa)', () {
    final youtubePage = _parse('''
  window.LUTE_YT_DATA.videoId = "dQw4w9WgXcQ";
  window.LUTE_YT_DATA.audioUrl = null;
  window.LUTE_YT_DATA.cues = [];
  window.LUTE_YT_DATA.bookId = 7;
  window.LUTE_YT_DATA.startPos = 0;
''');
    expect(youtubePage.youtube, isNotNull);
    expect(youtubePage.bilibili, isNull);

    final biliPage = _parse(_bilibiliBlock());
    expect(biliPage.bilibili, isNotNull);
    expect(biliPage.youtube, isNull);
    expect(
      biliPage.isVideoBook,
      isTrue,
      reason: 'bilibili books must count as video-book pages',
    );
  });

  test('a plain text book exposes neither video player', () {
    final page = _parse('''
  window.LUTE_YT_DATA.audioUrl = null;
  window.LUTE_YT_DATA.cues = [];
  window.LUTE_YT_DATA.bookId = 7;
''');

    expect(page.youtube, isNull);
    expect(page.bilibili, isNull);
    expect(page.isVideoBook, isFalse);
  });
}
