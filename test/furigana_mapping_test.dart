// Contract tests for the reader's furigana batching / filtering rules.
//
// These are the rules the web reader implements in
// `lute/static/js/lute-furigana.js`, and the reader must match them or the
// two clients disagree about what gets a reading:
//
//   * only word cells participate (the web's `span.word`, here
//     `wordId != null`), grouped by the server's paragraph id;
//   * the context text sent to the server is the word tokens joined --
//     punctuation excluded, exactly like the web's `tokens.join("")`;
//   * a reading is shown only when it exists, differs from the word, and the
//     word needs a reading under the page's script (`needs_reading`): a
//     kanji, or any Thai character when the script is "thai";
//   * a page whose word cells contain none of that script is never asked
//     about at all, which is what keeps the default-on setting from firing
//     requests on every Latin / Cyrillic / hangul book.
//
// 运行：flutter test test/furigana_mapping_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/utils/furigana_annotator.dart';

TextItem _item(
  String text, {
  int? wordId,
  int paragraphId = 0,
  int order = 0,
  int sentenceId = 0,
}) {
  return TextItem(
    text: text,
    statusClass: 'status0',
    wordId: wordId,
    sentenceId: sentenceId,
    paragraphId: paragraphId,
    isStartOfSentence: false,
    order: order,
  );
}

void main() {
  group('hasKanji', () {
    test('matches kanji and not kana / Latin', () {
      expect(hasKanji('夜'), isTrue);
      expect(hasKanji('聞こえ'), isTrue, reason: 'kana mixed with kanji');
      expect(hasKanji('よる'), isFalse);
      expect(hasKanji('トントン'), isFalse);
      expect(hasKanji('lute'), isFalse);
      expect(hasKanji('。'), isFalse);
    });
  });

  group('hasThai', () {
    test('matches Thai and not Han / kana / Latin', () {
      expect(hasThai('สวัสดี'), isTrue);
      expect(hasThai('การอ่าน'), isTrue);
      expect(hasThai('夜'), isFalse);
      expect(hasThai('よる'), isFalse);
      expect(hasThai('lute'), isFalse);
      expect(hasThai('。'), isFalse);
    });
  });

  group('pageNeedsReadings', () {
    test('true when a word cell carries a kanji', () {
      expect(
        pageNeedsReadings([
          _item('の', wordId: 1),
          _item('夜', wordId: 2),
        ]),
        isTrue,
      );
    });

    test('false for an all-kana page', () {
      expect(
        pageNeedsReadings([
          _item('よる', wordId: 1),
          _item('に', wordId: 2),
        ]),
        isFalse,
      );
    });

    test('kanji outside a word cell does not count', () {
      expect(
        pageNeedsReadings([
          _item('夜', wordId: null),
          _item('の', wordId: 1),
        ]),
        isFalse,
        reason: 'only word cells can receive a reading',
      );
    });

    test('thai script: a Thai word triggers the request', () {
      expect(
        pageNeedsReadings([
          _item('สวัสดี', wordId: 1),
          _item('ครับ', wordId: 2),
        ], script: 'thai'),
        isTrue,
        reason: 'Thai script shows no pronunciation of its own -- every word',
      );
    });

    test('thai script: a page without Thai words does not', () {
      expect(
        pageNeedsReadings([
          _item('the', wordId: 1),
          _item('book', wordId: 2),
        ], script: 'thai'),
        isFalse,
      );
    });

    test('a Thai word without the thai script does not trigger', () {
      expect(
        pageNeedsReadings([_item('สวัสดี', wordId: 1)]),
        isFalse,
        reason: 'null script (older server) keeps the han-only rule',
      );
      expect(
        pageNeedsReadings([_item('สวัสดี', wordId: 1)], script: 'han'),
        isFalse,
        reason: 'an older server would answer reading: null anyway',
      );
    });

    test('thai script: Thai outside a word cell does not count', () {
      expect(
        pageNeedsReadings([
          _item('สวัสดี', wordId: null),
          _item('ครับ', wordId: 1),
        ], script: 'thai'),
        isTrue,
        reason: 'the word cell below still triggers it',
      );
      expect(
        pageNeedsReadings([_item('สวัสดี', wordId: null)], script: 'thai'),
        isFalse,
        reason: 'only word cells can receive a reading',
      );
    });
  });

  group('buildFuriganaBatches', () {
    test('groups by the server paragraph id, word cells only', () {
      final batches = buildFuriganaBatches([
        _item('夜', wordId: 1, paragraphId: 0, order: 0),
        _item('、', wordId: null, paragraphId: 0, order: 1),
        _item('更け', wordId: 2, paragraphId: 0, order: 2),
        _item('朝', wordId: 3, paragraphId: 1, order: 3),
      ]);

      expect(batches, hasLength(2));

      expect(batches[0].tokens, ['夜', '更け']);
      expect(
        batches[0].fullText,
        '夜更け',
        reason: 'punctuation is excluded, as in the web reader',
      );
      expect(batches[1].tokens, ['朝']);
    });

    test('sends the raw token, zero-width space included', () {
      final batches = buildFuriganaBatches([
        _item('夜\u200B', wordId: 1, order: 0),
      ]);

      expect(
        batches.single.tokens.single,
        '夜\u200B',
        reason: "the web sends dataset.text; displayText is render-only",
      );
    });

    test('a page with no word cells yields no batches', () {
      expect(buildFuriganaBatches([_item('。', order: 0)]), isEmpty);
    });
  });

  group('mergeBatchReadings', () {
    test('maps readings positionally onto the word cells', () {
      final batch = buildFuriganaBatches([
        _item('夜', wordId: 1, order: 0),
        _item('更け', wordId: 2, order: 1),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['よる', 'ふけ']);

      expect(out, {'0-0-1': 'よる', '0-1-2': 'ふけ'});
    });

    test('drops a reading equal to the word, a missing one, and a kana word',
        () {
      final batch = buildFuriganaBatches([
        _item('夜', wordId: 1, order: 0),
        _item('更け', wordId: 2, order: 1),
        _item('よる', wordId: 3, order: 2),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['夜', null, 'よる']);

      expect(
        out,
        isEmpty,
        reason: 'reading == word, null reading and a kana word are all skipped',
      );
    });

    test('a short response leaves the tail unannotated', () {
      final batch = buildFuriganaBatches([
        _item('夜', wordId: 1, order: 0),
        _item('更け', wordId: 2, order: 1),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['よる']);

      expect(out, {'0-0-1': 'よる'});
    });

    test('a blank reading is treated as none', () {
      final batch = buildFuriganaBatches([
        _item('夜', wordId: 1, order: 0),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['  ']);

      expect(out, isEmpty);
    });

    test('thai script: a Thai word keeps its RTGS reading', () {
      final batch = buildFuriganaBatches([
        _item('สวัสดี', wordId: 1, order: 0),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, [
        'sa\u0300wa\u0300tdi',
      ], script: 'thai');

      expect(
        out,
        {'0-0-1': 'sa\u0300wa\u0300tdi'},
        reason: 'the han guard must not drop Thai readings; combining tone '
            'marks are stored verbatim',
      );
    });

    test('the same reading is dropped without the thai script', () {
      final batch = buildFuriganaBatches([
        _item('สวัสดี', wordId: 1, order: 0),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['sa\u0300wa\u0300tdi']);

      expect(
        out,
        isEmpty,
        reason: 'default (null) script is the han rule, unchanged',
      );
    });

    test('thai script: reading == word, null and blank are still dropped', () {
      final batch = buildFuriganaBatches([
        _item('สวัสดี', wordId: 1, order: 0),
        _item('ครับ', wordId: 2, order: 1),
        _item('ใช่', wordId: 3, order: 2),
      ]).single;

      final out = <String, String>{};
      mergeBatchReadings(out, batch, ['สวัสดี', null, '  '], script: 'thai');

      expect(out, isEmpty);
    });
  });
}
