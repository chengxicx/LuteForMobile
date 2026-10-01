// 影子跟读打分结果(POST /read/shadowing/transcribe 的 JSON)契约测试。
//
// 服务端 lute/read/routes.py 的 shadowing_transcribe 返回的字段这里逐个
// 钉住,重点三处容易错的映射:
//
//   1. statuses 是与上传 token 平行的数组,值 0/1/2 = 漏读/错读/读对
//      (lute/read/shadowing.py 的 STATUS_*),未知值按漏读处理 —— 宁可
//      多标一个错也不把没读过的词标成对的;
//   2. spoken_for_fuzzy 在 JSON 里 key 是**字符串**(index -> 实际听到的
//      词),dart 解析后必须转回 int key,面板才能把"读错的词"对上位;
//   3. 全字段可缺省:服务端版本更新加字段、或某项为 null 时不炸,回默认值。
//
// 运行:flutter test test/shadowing_result_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/shadowing/models/shadowing_result.dart';

void main() {
  test('parses a full server response', () {
    final result = ShadowingResult.fromJson({
      'transcription': '緑色の風が吹いています',
      'statuses': [2, 2, 1, 0],
      'spoken_for_fuzzy': {'2': '風ぎ'},
      'extras': ['えっと'],
      'score': 62,
      'matched': 2,
      'fuzzy': 1,
      'total': 4,
      'duration': 3.42,
      'tokens_per_minute': 70.2,
      'token_kind': 'morpheme',
    });

    expect(result.transcription, '緑色の風が吹いています');
    expect(result.statuses, [
      ShadowingTokenStatus.match,
      ShadowingTokenStatus.match,
      ShadowingTokenStatus.fuzzy,
      ShadowingTokenStatus.miss,
    ]);
    expect(result.spokenForFuzzy, {2: '風ぎ'});
    expect(result.extras, ['えっと']);
    expect(result.score, 62);
    expect(result.matched, 2);
    expect(result.fuzzy, 1);
    expect(result.total, 4);
    expect(result.duration, 3.42);
    expect(result.tokensPerMinute, 70.2);
    expect(result.tokenKind, 'morpheme');
  });

  test('unknown status values count as a miss', () {
    // 服务端将来加新判词(或返回脏数据)时,未知值宁可当漏读。
    final result = ShadowingResult.fromJson({
      'statuses': [0, 1, 2, 3, null],
    });
    expect(result.statuses, [
      ShadowingTokenStatus.miss,
      ShadowingTokenStatus.fuzzy,
      ShadowingTokenStatus.match,
      ShadowingTokenStatus.miss,
      ShadowingTokenStatus.miss,
    ]);
  });

  test('spoken_for_fuzzy ignores malformed entries', () {
    final result = ShadowingResult.fromJson({
      'spoken_for_fuzzy': {
        '2': 'かぜ',
        'not-a-number': 'x',
        '7': 42, // 非字符串的"听到的词"丢弃
      },
    });
    expect(result.spokenForFuzzy, {2: 'かぜ'});
  });

  test('missing and null fields fall back to defaults', () {
    final result = ShadowingResult.fromJson({});
    expect(result.transcription, '');
    expect(result.statuses, isEmpty);
    expect(result.spokenForFuzzy, isEmpty);
    expect(result.extras, isEmpty);
    expect(result.score, 0);
    expect(result.matched, 0);
    expect(result.fuzzy, 0);
    expect(result.total, 0);
    expect(result.duration, 0);
    expect(result.tokensPerMinute, isNull);
    expect(result.tokenKind, 'word');
  });

  test('parses the annotated heard sentence with furigana readings', () {
    // transcription_tokens 是服务端对识别结果逐词标注后的形态:面板据此
    // 画假名,并把每个词做成可点击发音的目标。
    final result = ShadowingResult.fromJson({
      'transcription': '天気がいい',
      'transcription_tokens': [
        {'text': '天気', 'reading': 'てんき'},
        {'text': 'が', 'reading': null},
        {'text': 'いい', 'reading': ''}, // 空串与 null 同等:无假名
      ],
    });
    expect(result.transcriptionTokens, hasLength(3));
    expect(result.transcriptionTokens[0].text, '天気');
    expect(result.transcriptionTokens[0].reading, 'てんき');
    expect(result.transcriptionTokens[1].reading, isNull);
    expect(result.transcriptionTokens[2].reading, isNull);
  });

  test('transcription_tokens defaults to empty when absent', () {
    final result = ShadowingResult.fromJson({});
    expect(result.transcriptionTokens, isEmpty);
  });

  test('numeric JSON values may arrive as int or double', () {
    // duration 走 round(duration, 2),可能是 int 形态的 3;tokens_per_minute
    // 可能是 70 而不是 70.2。
    final result = ShadowingResult.fromJson({
      'duration': 3,
      'tokens_per_minute': 70,
      'score': 100,
    });
    expect(result.duration, 3.0);
    expect(result.tokensPerMinute, 70.0);
    expect(result.score, 100);
  });
}
