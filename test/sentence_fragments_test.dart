import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/sentence_fragments.dart';

void main() {
  group('splitCombinedSentence', () {
    test('按句末标点拆开合并句，标点留在片段里', () {
      expect(
        splitCombinedSentence(
          'あ、やっとつながった。 今日はどうしたんですか。',
        ),
        ['あ、やっとつながった。', '今日はどうしたんですか。'],
      );
    });

    test('问号和叹号也是句子边界', () {
      expect(
        splitCombinedSentence('上田：え？ あ、そうだ、今日約束していましたね。'),
        ['上田：え？', 'あ、そうだ、今日約束していましたね。'],
      );
      expect(splitCombinedSentence('すごい！ 本当？'), ['すごい！', '本当？']);
    });

    test('全角空格与零宽空格先规范化，不留进片段', () {
      expect(
        splitCombinedSentence('雨が降る。\u3000\u200b風が吹く。'),
        ['雨が降る。', '風が吹く。'],
      );
    });

    test('没有句末标点时按空白拆（合并器用空格连接）', () {
      expect(splitCombinedSentence('ユニット1 第16課'), ['ユニット1', '第16課']);
    });

    test('半角句点只在后跟空白或结尾时切开', () {
      expect(splitCombinedSentence('A. B.'), ['A.', 'B.']);
    });

    test('单句返回空列表，避免重复查整句那个 key', () {
      expect(splitCombinedSentence('雨が降る。'), isEmpty);
      expect(splitCombinedSentence('  雨が降る。  '), isEmpty);
      expect(splitCombinedSentence(''), isEmpty);
    });

    test('片段去重且不超过上限', () {
      expect(
        splitCombinedSentence('同じ。 同じ。 違う。'),
        ['同じ。', '違う。'],
      );
      final tooMany = List.generate(13, (i) => '句$i。').join(' ');
      expect(splitCombinedSentence(tooMany), isEmpty);
    });
  });

  group('mergeSentenceAiResults', () {
    test('译文换行拼接，列表累加，语境取第一个非空', () {
      final merged = mergeSentenceAiResults([
        {
          'translation': '第一句译',
          'segments': [
            {'part': '雨', 'meaning': 'rain'},
          ],
          'grammar': [
            {'point': 'は'},
          ],
          'examples': [
            {'source': '例1'},
          ],
        },
        {
          'translation': '第二句译',
          'context': '语境',
          'segments': [
            {'part': '風', 'meaning': 'wind'},
          ],
          'examples': [
            {'source': '例2'},
          ],
        },
      ]);
      expect(merged['translation'], '第一句译\n第二句译');
      expect(merged['segments'], hasLength(2));
      expect(merged['grammar'], hasLength(1));
      expect(merged['examples'], hasLength(2));
      expect(merged['context'], '语境');
    });

    test('空输入、空译文、非法列表都安全', () {
      expect(mergeSentenceAiResults([]), isEmpty);
      final merged = mergeSentenceAiResults([
        {'translation': '  ', 'segments': 'not a list', 'context': 42},
      ]);
      expect(merged, isEmpty);
    });
  });
}
