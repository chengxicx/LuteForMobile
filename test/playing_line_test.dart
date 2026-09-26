// 播放行解析（cue → 页面句子）契约测试。
//
// 网页端由 lute/static/js/lute-playing-line.js 决定「播放到正文哪一行」，
// 移动端由 PlayingLine 复刻同一套规则（LUTE_PAGE_CUE_MAP 定位 + 文本校验，
// 校验不过再回退到按文本匹配）。这里钉住四件事：
//
//   1. 服务端的行→cue 映射对得上时按它定位；一个 cue 跨多行时多行一起标记；
//   2. 映射对不上（正文被手工改过、页面有空行导致长度不符）时回退按 cue
//      文本匹配，而不是把标记画到错误的行上；
//   3. 重复的行只标第一处（副歌那种重复行不该整页亮起来）；
//   4. cue 不在本页时返回空集 —— 而不是猜一行标上去。
//
// 运行：flutter test test/playing_line_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/models/youtube_data.dart';
import 'package:song_mobile/features/reader/utils/playing_line.dart';

/// 一个 `.textsentence` span：共享同一个 sentenceId 与服务端段落号的一段词。
///
/// 解析器是**按 span 切**的，而媒体书的一行（一个字幕 cue）可能被分词器切成
/// 好几个 span —— 所以「行」要按 paragraphId 把连续的 span 合起来。
Paragraph _sentence({
  required int sentenceId,
  required int paragraphId,
  required String text,
}) {
  return Paragraph(
    id: sentenceId,
    textItems: [
      TextItem(
        text: text,
        statusClass: 'status0',
        sentenceId: sentenceId,
        paragraphId: paragraphId,
        isStartOfSentence: true,
        order: 0,
      ),
    ],
  );
}

Set<int> _resolve({
  required List<Paragraph> paragraphs,
  List<int> pageCueMap = const [],
  required int cueIndex,
  required String cueText,
}) {
  return PlayingLine.sentenceIdsForCue(
    paragraphs: paragraphs,
    pageCueMap: pageCueMap,
    cueIndex: cueIndex,
    cueText: cueText,
  );
}

void main() {
  group('按行→cue 映射定位', () {
    final threeLines = [
      _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
      _sentence(sentenceId: 2, paragraphId: 2, text: '第二行'),
      _sentence(sentenceId: 3, paragraphId: 3, text: '第三行'),
    ];

    test('命中 cue 索引所在的那一行', () {
      expect(
        _resolve(
          paragraphs: threeLines,
          pageCueMap: [10, 11, 12],
          cueIndex: 11,
          cueText: '第二行',
        ),
        {2},
      );
    });

    test('一行被切成多句时整行一起标记', () {
      // 「第二行」被分词器切成了两句，但它们同属一个服务端段落。
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
        _sentence(sentenceId: 2, paragraphId: 2, text: '第二行前半'),
        _sentence(sentenceId: 3, paragraphId: 2, text: '第二行后半'),
        _sentence(sentenceId: 4, paragraphId: 3, text: '第三行'),
      ];

      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [10, 11, 12],
          cueIndex: 11,
          cueText: '第二行前半第二行后半',
        ),
        {2, 3},
      );
    });

    test('一个 cue 跨多行时这些行一起标记', () {
      // 多行字幕：同一个 cue 索引出现在两行上。
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
        _sentence(sentenceId: 2, paragraphId: 2, text: '第二行'),
        _sentence(sentenceId: 3, paragraphId: 3, text: '第三行'),
      ];

      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [10, 11, 11],
          cueIndex: 11,
          cueText: '第二行第三行',
        ),
        {2, 3},
      );
    });
  });

  group('映射不可信时回退到文本匹配', () {
    test('映射长度不符（页面有空行）时仍能按文本找到', () {
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
        _sentence(sentenceId: 2, paragraphId: 2, text: '第二行'),
      ];

      // 服务端按 <p> 计数（含空行），这里只有 2 个有内容的行。
      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [10, 11, 12, 13],
          cueIndex: 11,
          cueText: '第二行',
        ),
        {2},
      );
    });

    test('映射对不上（正文被改过）时不会标错行', () {
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '改过的第一行'),
        _sentence(sentenceId: 2, paragraphId: 2, text: '原始第二行'),
        _sentence(sentenceId: 3, paragraphId: 3, text: '原始第二行'),
      ];

      // 映射说 cue 10 在第一行，但那行的文本已经不是该 cue 的内容了：
      // 宁可回退按文本匹配，也不能把标记画在改过的第一行上。
      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [10, 11, 12],
          cueIndex: 10,
          cueText: '原始第二行',
        ),
        {2},
        reason: '回退匹配只取第一处，不能两行都亮',
      );
    });

    test('没有映射（旧服务端）时按文本匹配', () {
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
        _sentence(sentenceId: 2, paragraphId: 2, text: '第二行'),
      ];

      expect(
        _resolve(paragraphs: paragraphs, cueIndex: 7, cueText: '第二行'),
        {2},
      );
    });

    test('空白与零宽空格不影响匹配', () {
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: 'hello  world\u200b'),
      ];

      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [3],
          cueIndex: 3,
          cueText: 'hello world',
        ),
        {1},
      );
    });
  });

  group('找不到就不标', () {
    test('cue 不在本页时返回空集', () {
      final paragraphs = [
        _sentence(sentenceId: 1, paragraphId: 1, text: '第一行'),
      ];

      expect(
        _resolve(
          paragraphs: paragraphs,
          pageCueMap: [10],
          cueIndex: 42,
          cueText: '别的页面的行',
        ),
        isEmpty,
      );
    });

    test('播放头不在任何 cue 内（索引 -1）时返回空集', () {
      expect(
        _resolve(
          paragraphs: [_sentence(sentenceId: 1, paragraphId: 1, text: '第一行')],
          pageCueMap: [10],
          cueIndex: -1,
          cueText: '第一行',
        ),
        isEmpty,
      );
    });

    test('空页面返回空集', () {
      expect(
        _resolve(paragraphs: const [], cueIndex: 0, cueText: '第一行'),
        isEmpty,
      );
    });
  });

  group('播放头落在哪个 cue', () {
    const cues = [
      YoutubeCue(start: 1, end: 2, text: 'one'),
      YoutubeCue(start: 3, end: 4, text: 'two'),
    ];

    test('区间内命中', () {
      expect(PlayingLine.cueIndexAt(cues, 1.0), 0);
      expect(PlayingLine.cueIndexAt(cues, 1.99), 0);
      expect(PlayingLine.cueIndexAt(cues, 3.5), 1);
    });

    test('间隙、区间外与结束时都不属于任何 cue', () {
      expect(PlayingLine.cueIndexAt(cues, 0.5), -1, reason: '第一句之前');
      expect(PlayingLine.cueIndexAt(cues, 2.5), -1, reason: '两句之间的空隙');
      expect(PlayingLine.cueIndexAt(cues, 4.0), -1, reason: 'cue 的 end 是开区间');
      expect(PlayingLine.cueIndexAt(const [], 1.0), -1);
    });
  });
}
