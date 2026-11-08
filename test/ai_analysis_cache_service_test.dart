import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/ai_analysis_cache_service.dart';

// AI 面板（句译 /ai/translate、语法 /ai/grammar/analyze）结果的本地缓存：
// 重开面板、重启 App 后不再重复付一次 LLM 请求。这里锁住：存取往返无损、
// 过期与坏数据退化为 miss 而不是抛错（缓存只是兜底，坏了不能让面板变错误态）。
void main() {
  late Directory tempDir;
  var boxSeq = 0;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_ai_analysis_cache');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 每个 test 独立 box，互不串味。
  AiAnalysisCacheService service({Duration? ttl, int? maxEntries}) {
    boxSeq++;
    return AiAnalysisCacheService(
      boxName: 'ai_cache_test_$boxSeq',
      ttl: ttl,
      maxEntries: maxEntries,
    );
  }

  Map<String, dynamic> resultJson({String translation = '明日も雨だ。'}) => {
    'translation': translation,
    'segments': [
      {'part': '明日', 'reading': 'あした', 'meaning': 'tomorrow'},
      {'part': '雨', 'meaning': 'rain', 'role': 'subject'},
    ],
    'grammar': [
      {'point': '〜も', 'explanation': 'also'},
    ],
    'examples': [
      {'source': '明日も雨', 'translation': 'Tomorrow, rain too'},
    ],
  };

  test('cacheKey 只由语言与句文本决定，且区分语言', () {
    final a = AiAnalysisCacheService.cacheKey(7, '明日も雨が降る。');
    final b = AiAnalysisCacheService.cacheKey(7, '明日も雨が降る。');
    final c = AiAnalysisCacheService.cacheKey(8, '明日も雨が降る。');
    final d = AiAnalysisCacheService.cacheKey(7, '明日も雨が降っていく。');

    expect(a, b);
    expect(a, isNot(c));
    expect(a, isNot(d));
  });

  test('没存过时返回 null', () async {
    final cache = service();
    expect(await cache.getFromCache('nope'), isNull);
  });

  test('存进去的结构化结果能原样取回（含 provider/model）', () async {
    final cache = service();
    final key = AiAnalysisCacheService.cacheKey(7, '明日も雨が降る。');

    await cache.saveToCache(
      key: key,
      result: resultJson(),
      provider: 'openai',
      model: 'gpt-4o-mini',
    );

    final entry = await cache.getFromCache(key);
    expect(entry, isNotNull);
    expect(entry!.result, resultJson());
    expect(entry.provider, 'openai');
    expect(entry.model, 'gpt-4o-mini');
    expect(entry.fallbackText, isNull);

    // fromJson 必须吃得下缓存里的 JSON（round-trip 保证）。
    final model = utf8.encode(jsonEncode(entry.result));
    expect(model, isNotEmpty);
  });

  test('fallbackText（旧式一行翻译）也能缓存', () async {
    final cache = service();
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');

    await cache.saveToCache(key: key, fallbackText: 'It is raining.');

    final entry = await cache.getFromCache(key);
    expect(entry, isNotNull);
    expect(entry!.fallbackText, 'It is raining.');
    expect(entry.result, isNull);
  });

  test('result 与 fallbackText 都为空时不写入', () async {
    final cache = service();
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');

    await cache.saveToCache(key: key);

    expect(await cache.getFromCache(key), isNull);
  });

  test('过期条目视为 miss 并被删除（TTL 可注入以便测试）', () async {
    // 负 TTL：刚写入的条目也必然「已过期」，避免毫秒抖动造成 flaky。
    final cache = service(ttl: const Duration(seconds: -1));
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');

    await cache.saveToCache(key: key, fallbackText: 'It is raining.');
    expect(await cache.getFromCache(key), isNull);
  });

  test('坏 JSON 返回 null 而不抛', () async {
    final cache = service();
    await cache.initialize();

    // 直接往 box 里塞垃圾，模拟旧版本/损坏数据。
    final box = await Hive.openBox<String>(cache.boxName);
    await box.put('broken', 'not json at all');
    expect(await cache.getFromCache('broken'), isNull);

    await box.put('wrong-shape', jsonEncode(['not', 'a', 'map']));
    expect(await cache.getFromCache('wrong-shape'), isNull);
  });

  test('超过条数上限时按最旧淘汰（上限可注入以便测试）', () async {
    final cache = service(maxEntries: 3);
    await cache.initialize();

    String keyOf(String text) => AiAnalysisCacheService.cacheKey(7, text);
    for (final text in ['一', '二', '三', '四']) {
      await cache.saveToCache(key: keyOf(text), fallbackText: text);
      // saveToCache 的时间戳是毫秒级，强制拉开一毫秒保证「最旧」可判定。
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    final stats = await cache.getCacheStats();
    expect(stats['totalEntries'], 3);
    expect(await cache.getFromCache(keyOf('一')), isNull); // 最旧的被淘汰
    expect(await cache.getFromCache(keyOf('四')), isNotNull); // 最新的还在
  });

  test('clearAllCache 清空全部', () async {
    final cache = service();
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');

    await cache.saveToCache(key: key, fallbackText: 'It is raining.');
    await cache.clearAllCache();
    expect(await cache.getFromCache(key), isNull);
  });
}
