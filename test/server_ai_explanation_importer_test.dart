import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/ai_analysis_cache_service.dart';
import 'package:song_mobile/features/reader/services/server_ai_explanation_importer.dart';

// 整本离线下载时把服务端**已经存下**的 AI 解释拉回本地。
// 核心风险是句子文本：服务端 airesults.sentence 是 clean_sentence 后的形式，
// 阅读页句子是 token 拼接（含 U+200B / U+3000），两边 key 不一致就是白拉。
void main() {
  late Directory tempDir;
  var boxSeq = 0;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_server_ai_import');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  AiAnalysisCacheService cache() {
    boxSeq++;
    return AiAnalysisCacheService(boxName: 'server_ai_import_$boxSeq');
  }

  Map<String, dynamic> payload(List<Map<String, dynamic>> items) => {
    'version': 1,
    'book_id': 1011,
    'lang_id': 13,
    'target_lang': 'zh',
    'model': 'mixed',
    'items': items,
  };

  test('cacheKey 与服务端 clean_sentence 规则对齐', () {
    const fromPage =
        '\u200b第\u200b16\u200b課\u200b\u3000\u200bお\u200b久しぶり\u200b、'
        '\u200b元気\u200bだった\u200b？\u200b';
    const fromServer = '第16課 お久しぶり、元気だった？';

    expect(
      AiAnalysisCacheService.cacheKey(13, fromPage),
      AiAnalysisCacheService.cacheKey(13, fromServer),
    );
    // 老 key 仍可单独算出来，读缓存时用来兜底。
    expect(
      AiAnalysisCacheService.cacheKey(13, fromServer),
      isNot(AiAnalysisCacheService.legacyCacheKey(13, fromPage)),
    );
  });

  test('服务端已有解释落成 pinned 离线资产，语法结果不混入', () async {
    final c = cache();
    final importer = ServerAiExplanationImporter(
      fetch: (bookId) async => payload([
        {
          'sentence': '今日は雨です。',
          'kind': 'sentence',
          'target_lang': 'zh',
          'translation': '今天下雨。',
          'segments': [
            {'part': '今日', 'meaning': '今天'},
          ],
          'grammar': <dynamic>[],
          'examples': <dynamic>[],
        },
        {
          'sentence': '明日は晴れです。',
          'kind': 'sentence',
          'translation': '明天晴天。',
        },
        {
          'sentence': '语法结果不该进来',
          'kind': 'grammar',
          'points': <dynamic>[],
        },
      ]),
      cache: c,
    );

    expect(await importer.importForBook(1011), 2);

    final entry = await c.getFromCache(
      AiAnalysisCacheService.cacheKey(13, '今日は雨です。'),
    );
    expect(entry, isNotNull);
    expect(entry!.result!['translation'], '今天下雨。');
    expect(entry.result!.containsKey('sentence'), isFalse);
    expect(entry.result!.containsKey('target_lang'), isFalse);
    expect(entry.pinned, isTrue);
    expect(entry.bookIds, contains(1011));
    expect(await c.countForBook(1011), 2);
    expect(
      await c.getFromCache(
        AiAnalysisCacheService.cacheKey(13, '语法结果不该进来'),
      ),
      isNull,
    );
  });

  test('阅读页原句（含零宽/全角空格）能命中从服务端拉回的解释', () async {
    const clean = 'お久しぶり、元気だった？';
    const fromPage = '\u200bお\u200b久しぶり\u200b、\u200b元気\u200bだった'
        '\u200b？\u200b';
    final c = cache();
    final importer = ServerAiExplanationImporter(
      fetch: (bookId) async => payload([
        {'sentence': clean, 'kind': 'sentence', 'translation': '好久不见。'},
      ]),
      cache: c,
    );

    expect(await importer.importForBook(1011), 1);
    final entry = await c.getFromCache(
      AiAnalysisCacheService.cacheKey(13, fromPage),
    );
    expect(entry, isNotNull);
    expect(entry!.result!['translation'], '好久不见。');
  });

  test('接口拿不到（断网 / 老服务端 / 空结果）时安全跳过', () async {
    final fetches = <AiExplanationExportFetch>[
      (bookId) async => null,
      (bookId) async => throw StateError('offline'),
      (bookId) async => <String, dynamic>{'items': <dynamic>[]},
      // 有内容但缺 lang_id：算不出缓存 key，宁可整批跳过也别乱落。
      (bookId) async => <String, dynamic>{
        'items': [
          {'sentence': '雨。', 'kind': 'sentence', 'translation': 'rain'},
        ],
      },
    ];
    for (final fetch in fetches) {
      final importer = ServerAiExplanationImporter(
        fetch: fetch,
        cache: cache(),
      );
      expect(await importer.importForBook(1011), 0);
    }
  });
}
