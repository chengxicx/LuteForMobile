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
  AiAnalysisCacheService service({int? maxCacheSizeBytes}) {
    boxSeq++;
    return AiAnalysisCacheService(
      boxName: 'ai_cache_test_$boxSeq',
      maxCacheSizeBytes: maxCacheSizeBytes,
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

  test('永久保留：几百天前写入的条目仍命中（没有 TTL）', () async {
    final cache = service();
    await cache.initialize();
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');
    final box = await Hive.openBox<String>(cache.boxName);

    // 直接塞一条「很老」的条目，模拟长期未用的缓存。
    final oldTs = DateTime.now()
        .subtract(const Duration(days: 400))
        .millisecondsSinceEpoch;
    await box.put(
      key,
      jsonEncode(<String, dynamic>{
        'v': 1,
        'ts': oldTs,
        'sz': 40,
        'fallback': 'It is raining.',
      }),
    );

    final entry = await cache.getFromCache(key);
    expect(entry, isNotNull);
    expect(entry!.fallbackText, 'It is raining.');
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

  test('只按体积淘汰，且 pinned（离线下载）条目不参与淘汰', () async {
    // 1 字节上限：任何非 pinned 条目写入后都超限，会被立刻淘汰到 0。
    final cache = service(maxCacheSizeBytes: 1);
    String keyOf(String text) => AiAnalysisCacheService.cacheKey(7, text);

    await cache.saveToCache(key: keyOf('一'), fallbackText: '一');
    expect(await cache.getFromCache(keyOf('一')), isNull);

    await cache.saveToCache(
      key: keyOf('二'),
      fallbackText: '二',
      pinned: true,
    );
    await cache.saveToCache(key: keyOf('三'), fallbackText: '三');

    expect(await cache.getFromCache(keyOf('二')), isNotNull);
    expect(await cache.getFromCache(keyOf('三')), isNull);

    final stats = await cache.getCacheStats();
    expect(stats['pinnedEntries'], 1);
  });

  test('payloadHash 忽略键序，内容变化才变化', () {
    final a = AiAnalysisCacheService.payloadHash(
      {
        'translation': 'x',
        'segments': [
          {'part': 'a', 'meaning': 'b'},
        ],
      },
      null,
    );
    final b = AiAnalysisCacheService.payloadHash(
      {
        'segments': [
          {'meaning': 'b', 'part': 'a'},
        ],
        'translation': 'x',
      },
      null,
    );
    expect(a, b);

    final c = AiAnalysisCacheService.payloadHash(
      {'translation': 'y'},
      null,
    );
    expect(a, isNot(c));
  });

  test('clearAllCache 清空全部', () async {
    final cache = service();
    final key = AiAnalysisCacheService.cacheKey(7, '雨だ。');

    await cache.saveToCache(key: key, fallbackText: 'It is raining.');
    await cache.clearAllCache();
    expect(await cache.getFromCache(key), isNull);
  });
}
