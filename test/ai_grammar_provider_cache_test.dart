import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/ai_analysis_cache_service.dart';
import 'package:song_mobile/core/cache/providers/ai_analysis_cache_provider.dart';
import 'package:song_mobile/features/grammar/models/ai_grammar_result.dart';
import 'package:song_mobile/features/grammar/providers/ai_grammar_provider.dart';

/// Pins the AI grammar panel's local cache: a re-opened panel (or the word
/// card's Grammar tab after a restart) answers from cache instead of paying
/// another LLM round trip, and Retry really asks the network again.
void main() {
  late Directory tempDir;
  var boxSeq = 0;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_grammar_ai_provider');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const langId = 7;
  const sentence = '雨が降っている。';

  AiGrammarResult resultOf(String translation) => AiGrammarResult(
    translation: translation,
    clauses: [
      const AiGrammarClause(type: 'subordinate', text: '雨が降っている'),
    ],
  );

  Stream<AiGrammarEvent> okStream(AiGrammarResult result) async* {
    yield const AiGrammarMetaEvent(
      cached: false,
      provider: 'gemini',
      model: 'gemini-flash',
    );
    yield AiGrammarResultEvent(result: result);
    yield const AiGrammarDoneEvent();
  }

  Stream<AiGrammarEvent> errorStream(String kind) async* {
    yield AiGrammarErrorEvent(kind: kind, message: 'kind=$kind');
    yield const AiGrammarDoneEvent();
  }

  Future<void> waitForCondition(
    bool Function() ok,
    String description, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (ok()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('not reached in time: $description');
  }

  /// 等到状态满足谓词为止——不能只等 status：连续两次 analyze 的终态可能
  /// 同为 done/error，轮询会立刻读到上一次的旧状态。
  Future<AiGrammarState> waitForState(
    ProviderContainer container,
    bool Function(AiGrammarState) test,
  ) async {
    AiGrammarState? seen;
    await waitForCondition(
      () {
        seen = container.read(aiGrammarProvider);
        return test(seen!);
      },
      'grammar AI state predicate',
    );
    return seen!;
  }

  test('首次走网络并写缓存；重开面板直接命中缓存', () async {
    var callCount = 0;
    final cache = AiAnalysisCacheService(
      boxName: 'grammar_ai_provider_${++boxSeq}',
    );
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        aiGrammarAnalyzeProvider.overrideWithValue(
          ({required String sentence, required int langId}) {
            calls.add('$langId|$sentence');
            callCount++;
            return okStream(resultOf('gram-$callCount'));
          },
        ),
        aiGrammarCacheServiceProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(aiGrammarProvider.notifier);

    notifier.analyze(sentence: sentence, langId: langId);
    final first = await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.done && s.result?.translation == 'gram-1',
    );
    expect(first.isCached, isFalse);
    expect(calls.length, 1);
    await waitForCacheEntryNow(cache);

    // 第二次打开（模拟换句后回来）：缓存命中，同一份结果。
    notifier.analyze(sentence: sentence, langId: langId);
    final second = await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.done && s.isCached,
    );
    expect(second.result?.translation, 'gram-1');
    expect(calls.length, 1);
  });

  test('forceNetwork 绕过缓存，成功后照常回写', () async {
    var callCount = 0;
    final cache = AiAnalysisCacheService(
      boxName: 'grammar_ai_provider_${++boxSeq}',
    );
    final container = ProviderContainer(
      overrides: [
        aiGrammarAnalyzeProvider.overrideWithValue(
          ({required String sentence, required int langId}) {
            callCount++;
            return okStream(resultOf('gram-$callCount'));
          },
        ),
        aiGrammarCacheServiceProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(aiGrammarProvider.notifier);

    notifier.analyze(sentence: sentence, langId: langId);
    await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.done && s.result?.translation == 'gram-1',
    );
    await waitForCacheEntryNow(cache);

    notifier.analyze(
      sentence: sentence,
      langId: langId,
      forceNetwork: true,
    );
    final retried = await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.done && s.result?.translation == 'gram-2',
    );
    expect(retried.sentence, sentence);
  });

  test('错误结果不写缓存，重开面板会重试网络', () async {
    final failingCalls = <String>[];
    final cache = AiAnalysisCacheService(
      boxName: 'grammar_ai_provider_${++boxSeq}',
    );
    final container = ProviderContainer(
      overrides: [
        aiGrammarAnalyzeProvider.overrideWithValue(
          ({required String sentence, required int langId}) {
            failingCalls.add('$langId|$sentence');
            // 两次错误用不同 kind，让「第二次真的发生」可判定。
            return errorStream(
              failingCalls.length == 1 ? 'rate' : 'timeout',
            );
          },
        ),
        aiGrammarCacheServiceProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(aiGrammarProvider.notifier);

    notifier.analyze(sentence: sentence, langId: langId);
    final first = await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.error && s.errorKind == 'rate',
    );
    expect(first.isCached, isFalse);
    expect(failingCalls.length, 1);

    // 重开：没有缓存可命中，再次真实请求。
    notifier.analyze(sentence: sentence, langId: langId);
    final second = await waitForState(
      container,
      (s) => s.status == AiGrammarStatus.error && s.errorKind == 'timeout',
    );
    expect(second.sentence, sentence);
    expect(failingCalls.length, 2);
    expect(await cache.getFromCache(
      AiAnalysisCacheService.cacheKey(langId, sentence),
    ), isNull);
  });
}

/// 等缓存条目真正落盘（同上，供三个测试共用）。
Future<void> waitForCacheEntryNow(AiAnalysisCacheService cache) async {
  final key = AiAnalysisCacheService.cacheKey(7, '雨が降っている。');
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (await cache.getFromCache(key) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('cache entry never appeared');
}
