// The mobile client builds the edge-tts request URL by hand:
//
//   '$serverUrl/tts/$_languageCode/${Uri.encodeComponent(text)}'
//
// so the sentence travels in a *path segment*, and the server routes it with
// Werkzeug's `path` converter.  That converter can fail on perfectly ordinary
// book text, and the failure is a 404 -- which this client deliberately reads
// as "something is actually wrong" (see `isSynthesisFailureResponse`), not as
// "skip this fragment".  The result was read-aloud dying on the first sentence
// that tripped it (Leaf 5C, 2026-09-27).
//
// Two ways to trip it, both verified against the installed Werkzeug source:
//
//   * `PathConverter.regex` is `[^/].*?` (routing/converters.py) and
//     `Rule._parse_rule` appends `\Z` to the final part (routing/rules.py), so
//     the segment must be consumed to the very end.
//   * `StateMachineMatcher` compiles that part with a bare
//     `re.compile(test_part.content)` (routing/matcher.py) -- no `re.DOTALL` --
//     so `.` will not match a newline, `.*?` stops short of it, and `\Z` can
//     never be satisfied.  A segment that *contains* a newline never matches.
//   * An *empty* segment has no `[^/]` to match either -- `/tts/ja-JP/` 404s.
//
// nginx logged the real one as:
//
//   GET /tts/ja-JP/%E4%BD%9C%E8%AF%8D%20%3A%20%E4%B8%8A%E6%B1%9F%E6%B4%8C%E6%B8%85%E4%BD%9C%0A  -> 404
//
// i.e. `作词 : 上江洌清作\n` -- a lyricist credit line whose text item ends
// with the server's line break.  HTML collapses that break, so nothing was
// visible on screen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/tts_service.dart';

/// Would the server's `/tts/<lang>/<text>` rule match this text as its final
/// path segment?  Mirrors the two failure modes above.
bool _isRoutable(String text) =>
    text.isNotEmpty && !text.contains('\n') && !text.contains('\r');

void main() {
  group('normalizeTtsText', () {
    test('the trailing newline that caused the 404 is removed', () {
      // The exact sentence from the report.
      const raw = '作词 : 上江洌清作\n';

      expect(
        _isRoutable(raw),
        isFalse,
        reason:
            'this is the request that 404s: the trailing %0A is a path '
            'segment the server cannot route',
      );

      final normalized = normalizeTtsText(raw);
      expect(normalized, '作词 : 上江洌清作');
      expect(_isRoutable(normalized), isTrue);
    });

    test('a line break anywhere in the sentence is neutralised', () {
      // Not just the trailing one -- a break in the middle breaks the same
      // regex, since `.*?` cannot cross it.
      const raw = '第一行\n第二行\r\n第三行\t';
      final normalized = normalizeTtsText(raw);

      expect(normalized, '第一行 第二行 第三行');
      expect(_isRoutable(normalized), isTrue);
    });

    test('text that cleans away to nothing normalizes to empty', () {
      // Callers must skip these rather than send them: `/tts/ja-JP/` has an
      // empty final segment and 404s as well.  See `_speakCurrent` and
      // `speakSentence`.
      for (final raw in <String>['', '   ', '\n', '\n \t\r\n', '\u200B\n ']) {
        final normalized = normalizeTtsText(raw);
        expect(
          normalized,
          isEmpty,
          reason: '${jsonEncode(raw)} must normalize to the empty string',
        );
        expect(_isRoutable(normalized), isFalse);
      }
    });

    test('zero-width characters are still stripped', () {
      // The original job of this helper, kept as a regression guard: on-device
      // engines treat U+200B as a word boundary and read a pause into it.
      expect(normalizeTtsText('まし\u200Bた'), 'ました');
      expect(normalizeTtsText('\uFEFF本文'), '本文');
    });

    test('runs of whitespace collapse to one space, not to nothing', () {
      // Matching the web player's `cleanSentenceText`, which collapses rather
      // than deletes -- a space is what keeps two words from fusing.
      expect(normalizeTtsText('作词  :  上江洌清作'), '作词 : 上江洌清作');
      expect(normalizeTtsText('  hello   world  '), 'hello world');
    });

    test('# is kept, unlike the web helper', () {
      // Deliberate deviation from `cleanSentenceText`: `#` and `＃` are legal
      // in a path segment, so they cannot cause the 404 above, and dropping
      // them would change how legitimate text such as `C#` reads.
      expect(normalizeTtsText('C#入門'), 'C#入門');
      expect(normalizeTtsText('＃見出し'), '＃見出し');
    });

    test('already-clean text passes through untouched', () {
      // The page this was reported on: nothing here may change, or the fix
      // would have moved the bug rather than removed it.
      for (final text in <String>[
        '日の暮れ、私は横浜に行きました。',
        '「私の趣味を見せましょう。',
        '」',
        '【一】',
        '文番号7のサンプル文です。',
      ]) {
        expect(normalizeTtsText(text), text);
      }
    });
  });
}
