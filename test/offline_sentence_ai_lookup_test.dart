import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/ai_analysis_cache_service.dart';
import 'package:song_mobile/features/reader/services/offline_sentence_ai_lookup.dart';

// 词卡 Sentence 面板断网时改读本地缓存：这里锁住「精确 → legacy → 片段」
// 三级查找。真机上 Sentence Reader 会把整页课文合成一句（22 段），所以
// 长合并句的片段回退必须有回归用例，不能只测两段的玩具句子。
void main() {
  late Directory tempDir;
  var boxSeq = 0;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_offline_ai_lookup');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  AiAnalysisCacheService cache() {
    boxSeq++;
    return AiAnalysisCacheService(boxName: 'offline_ai_lookup_$boxSeq');
  }

  Future<void> plant(
    AiAnalysisCacheService service,
    int langId,
    String sentence, {
    String? translation,
    String? fallbackText,
    bool legacy = false,
  }) async {
    final key = legacy
        ? AiAnalysisCacheService.legacyCacheKey(langId, sentence)
        : AiAnalysisCacheService.cacheKey(langId, sentence);
    final ok = await service.saveToCache(
      key: key,
      result: translation == null ? null : {'translation': translation},
      fallbackText: fallbackText,
    );
    expect(ok, isTrue, reason: '种缓存失败: $sentence');
  }

  group('精确 key', () {
    test('阅读页带零宽空格/全角空格的句子也能命中规范化后的条目', () async {
      final c = cache();
      const stored = 'あ、やっとつながった。';
      await plant(c, 13, stored, translation: '终于接通了。');

      const fromReader = 'あ、やっとつながった。\u200b\u3000';
      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: fromReader,
      );
      expect(entry, isNotNull);
      expect(entry!.result!['translation'], '终于接通了。');
    });

    test('升级前用 legacy key 写下的条目仍能读到', () async {
      final c = cache();
      const sentence = '今日はどうしたんですか。';
      await plant(c, 13, sentence, translation: '今天怎么了？', legacy: true);

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: sentence,
      );
      expect(entry, isNotNull);
      expect(entry!.result!['translation'], '今天怎么了？');
    });

    test('语言 ID 不同不算命中', () async {
      final c = cache();
      await plant(c, 13, '同じ文。', translation: '日语');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 99,
        sentence: '同じ文。',
      );
      expect(entry, isNull);
    });
  });

  group('合并句片段回退', () {
    test('两段的合并句按片段顺序拼接译文', () async {
      final c = cache();
      await plant(c, 13, 'あ、やっとつながった。', translation: '啊，终于接通了。');
      await plant(c, 13, '今日はどうしたんですか。', translation: '今天是怎么了？');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: 'あ、やっとつながった。 今日はどうしたんですか。',
      );
      expect(entry, isNotNull);
      expect(entry!.result!['translation'], '啊，终于接通了。\n今天是怎么了？');
    });

    test('只命中部分片段也返回结果，不因为缺一段就整句失败', () async {
      final c = cache();
      await plant(c, 13, '一つ目。', translation: '第一句');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: '一つ目。 二つ目。 三つ目。',
      );
      expect(entry, isNotNull);
      expect(entry!.result!['translation'], '第一句');
    });

    test('片段里的 legacy key 也认', () async {
      final c = cache();
      await plant(c, 13, '古い句。', translation: '老结果', legacy: true);
      await plant(c, 13, '新しい句。', translation: '新结果');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: '古い句。 新しい句。',
      );
      expect(entry!.result!['translation'], '老结果\n新结果');
    });

    test('纯文本 fallback 也参与拼接（老服务端只回一行译文）', () async {
      final c = cache();
      await plant(c, 13, '一つ目。', fallbackText: '第一句纯文本');
      await plant(c, 13, '二つ目。', fallbackText: '第二句纯文本');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: '一つ目。 二つ目。',
      );
      expect(entry, isNotNull);
      expect(entry!.fallbackText, '第一句纯文本\n第二句纯文本');
    });

    test('真机回归：22 段整页合并句，20 段命中全部拼上', () async {
      final c = cache();
      final parts = List<String>.generate(22, (i) => '第${i + 1}句。');
      for (var i = 0; i < 20; i++) {
        await plant(c, 13, parts[i], translation: '译文${i + 1}');
      }

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: parts.join(' '),
      );
      expect(entry, isNotNull);
      final lines = (entry!.result!['translation'] as String).split('\n');
      expect(lines.length, 20);
      expect(lines.first, '译文1');
      expect(lines.last, '译文20');
    });

    test('一段都没命中返回 null，交回联网路径', () async {
      final c = cache();
      await plant(c, 13, '別の文。', translation: '别的句子');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: '一つ目。 二つ目。',
      );
      expect(entry, isNull);
    });
  });

  group('provider 与词卡面板共用同一份片段实现', () {
    test('composeCachedSentenceAiFragments 单独调用结果一致', () async {
      final c = cache();
      await plant(c, 13, '甲。', translation: 'A');
      await plant(c, 13, '乙。', translation: 'B');

      final entry = await composeCachedSentenceAiFragments(
        cache: c,
        langId: 13,
        sentence: '甲。 乙。',
      );
      expect(entry!.result!['translation'], 'A\nB');
    });

    test('整句已有精确结果时不再按片段拆', () async {
      final c = cache();
      const sentence = '甲。 乙。';
      await plant(c, 13, sentence, translation: '整句完整译文');
      await plant(c, 13, '甲。', translation: 'A');
      await plant(c, 13, '乙。', translation: 'B');

      final entry = await lookupOfflineSentenceAi(
        cache: c,
        langId: 13,
        sentence: sentence,
      );
      expect(entry!.result!['translation'], '整句完整译文');
    });
  });
}
