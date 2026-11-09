import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/ai_analysis_cache_service.dart';
import 'package:song_mobile/core/cache/providers/ai_analysis_cache_provider.dart';
import 'package:song_mobile/features/reader/models/sentence_ai_result.dart';
import 'package:song_mobile/features/reader/providers/sentence_ai_provider.dart';

/// Pins the AI sentence panel's caching behaviour: a re-opened panel answers
/// from the local cache instead of paying another LLM round trip, an
/// in-flight prefetch is joined rather than duplicated, and Retry really
/// asks the network for a fresh answer.

/// The endpoint as a counting fake: records every call and pops the next
/// registered stream for that sentence, so a second call can return a
/// different payload than the first (让新旧状态可区分).
class _Endpoint {
  final calls = <String>[];
  final Map<String, List<Stream<SentenceAiEvent> Function()>> responses = {};

  Stream<SentenceAiEvent> call({
    required String sentence,
    required int langId,
  }) {
    final key = '$langId|$sentence';
    calls.add(key);
    final makers = responses[key];
    if (makers == null || makers.isEmpty) {
      throw StateError('unexpected endpoint call: $key');
    }
    return makers.removeAt(0)();
  }
}

void main() {
  late Directory tempDir;
  var boxSeq = 0;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_sentence_ai_provider');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const langId = 7;
  const sentenceA = '雨が降る。';
  const sentenceB = '風が吹く。';
  const sentenceC = '虹が出る。';

  SentenceAiResult resultOf(String translation) => SentenceAiResult(
    translation: translation,
    segments: [
      const SentenceAiSegment(part: '雨', meaning: 'rain'),
    ],
  );

  Stream<SentenceAiEvent> okStream(SentenceAiResult result) async* {
    yield const SentenceAiMetaEvent(
      cached: false,
      provider: 'openai',
      model: 'gpt-4o-mini',
    );
    yield SentenceAiResultEvent(result: result);
    yield const SentenceAiDoneEvent();
  }

  Stream<SentenceAiEvent> errorStream(String kind) async* {
    yield SentenceAiErrorEvent(kind: kind, message: 'kind=$kind');
    yield const SentenceAiDoneEvent();
  }

  ({ProviderContainer container, _Endpoint endpoint, AiAnalysisCacheService cache})
  makeContainer() {
    final endpoint = _Endpoint();
    boxSeq++;
    final cache = AiAnalysisCacheService(boxName: 'sentence_ai_provider_$boxSeq');

    final container = ProviderContainer(
      overrides: [
        sentenceAiAnalyzeProvider.overrideWithValue(endpoint.call),
        sentenceAiCacheServiceProvider.overrideWithValue(cache),
        // 短 dwell / 冷却，测试用真实异步等待即可，不引入 fake_async。
        sentenceAiProvider.overrideWith(
          () => SentenceAiNotifier(
            prefetchDwell: const Duration(milliseconds: 20),
            failureCooldown: const Duration(seconds: 60),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, endpoint: endpoint, cache: cache);
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
  /// 同为 done/error，轮询会立刻读到上一次的旧状态。谓词必须带上只有
  /// 「新」状态才有的属性（不同译文、isCached 等）。
  Future<SentenceAiState> waitForState(
    ProviderContainer container,
    bool Function(SentenceAiState) test,
  ) async {
    SentenceAiState? seen;
    await waitForCondition(
      () {
        seen = container.read(sentenceAiProvider);
        return test(seen!);
      },
      'sentence AI state predicate',
    );
    return seen!;
  }

  Future<void> waitForEndpointCalls(_Endpoint endpoint, int count) async {
    await waitForCondition(
      () => endpoint.calls.length >= count,
      'endpoint calls >= $count (got ${endpoint.calls.length})',
    );
  }

  test('首次走网络并写缓存；换句再回来直接命中缓存，不再调网络', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    endpoint.responses['$langId|$sentenceA'] = [() => okStream(resultOf('A'))];
    endpoint.responses['$langId|$sentenceB'] = [() => okStream(resultOf('B'))];

    final notifier = container.read(sentenceAiProvider.notifier);

    await notifier.analyze(sentence: sentenceA, langId: langId);
    final first = await waitForState(
      container,
      (s) =>
          s.sentence == sentenceA &&
          s.status == SentenceAiStatus.done &&
          s.result?.translation == 'A' &&
          !s.isCached,
    );
    expect(first.status, SentenceAiStatus.done);
    expect(endpoint.calls.length, 1);
    await waitForCacheEntry(cache, sentenceA);

    // 换一句，正常走网络。
    await notifier.analyze(sentence: sentenceB, langId: langId);
    await waitForState(
      container,
      (s) =>
          s.sentence == sentenceB &&
          s.status == SentenceAiStatus.done &&
          s.result?.translation == 'B',
    );
    expect(endpoint.calls.length, 2);
    await waitForCacheEntry(cache, sentenceB);

    // 回到第一句：本地缓存命中，不再付一次请求。
    await notifier.analyze(sentence: sentenceA, langId: langId);
    final back = await waitForState(
      container,
      (s) => s.sentence == sentenceA && s.status == SentenceAiStatus.done && s.isCached,
    );
    expect(back.result?.translation, 'A');
    expect(endpoint.calls.length, 2);
  });

  test('forceNetwork 绕过缓存重发请求，成功后照常回写缓存', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    // 两次调用返回不同译文，让「新请求真的完成」可判定。
    endpoint.responses['$langId|$sentenceA'] = [
      () => okStream(resultOf('A1')),
      () => okStream(resultOf('A2')),
    ];

    final notifier = container.read(sentenceAiProvider.notifier);
    await notifier.analyze(sentence: sentenceA, langId: langId);
    await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done && s.result?.translation == 'A1',
    );
    await waitForCacheEntry(cache, sentenceA);
    expect(endpoint.calls.length, 1);

    await notifier.analyze(
      sentence: sentenceA,
      langId: langId,
      forceNetwork: true,
    );
    final retried = await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done && s.result?.translation == 'A2',
    );
    expect(retried.sentence, sentenceA);
    expect(endpoint.calls.length, 2);
    await waitForCacheEntry(cache, sentenceA);
  });

  test('停留 dwell 后预取下两句并写缓存；打开对应面板秒出结果', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    endpoint.responses['$langId|$sentenceB'] = [() => okStream(resultOf('B'))];
    endpoint.responses['$langId|$sentenceC'] = [() => okStream(resultOf('C'))];

    final notifier = container.read(sentenceAiProvider.notifier);
    notifier.schedulePrefetch(
      upcoming: [sentenceB, sentenceC],
      langId: langId,
    );

    await waitForEndpointCalls(endpoint, 2);
    await waitForCacheEntry(cache, sentenceB);
    await waitForCacheEntry(cache, sentenceC);

    // 用户此时点开下一句的 AI 卡：缓存直接命中。
    await notifier.analyze(sentence: sentenceB, langId: langId);
    final state = await waitForState(
      container,
      (s) => s.sentence == sentenceB && s.status == SentenceAiStatus.done && s.isCached,
    );
    expect(state.result?.translation, 'B');
    expect(endpoint.calls.length, 2);
  });

  test('面板请求会合并进行中的预取，而不是对同一句发第二枪', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    final gate = Completer<void>();
    endpoint.responses['$langId|$sentenceB'] = [
      () async* {
        yield const SentenceAiMetaEvent(cached: false);
        await gate.future;
        yield SentenceAiResultEvent(result: resultOf('B'));
        yield const SentenceAiDoneEvent();
      },
    ];

    final notifier = container.read(sentenceAiProvider.notifier);
    notifier.schedulePrefetch(upcoming: [sentenceB], langId: langId);
    await waitForEndpointCalls(endpoint, 1);
    // 多给一点时间让 _inFlight 注册完成（面板 join 依赖它）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(endpoint.calls.length, 1); // 预取请求还挂着

    // 用户在此刻点开同一句的面板：应该加入在途请求。不直接 await——
    // join 要等预取流走完，而门控要在确认没发第二枪之后才放行。
    final joinFuture = notifier.analyze(sentence: sentenceB, langId: langId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(endpoint.calls.length, 1);

    gate.complete();
    await joinFuture;
    final state = await waitForState(
      container,
      (s) => s.sentence == sentenceB && s.status == SentenceAiStatus.done && s.isCached,
    );
    expect(state.result?.translation, 'B');
    expect(endpoint.calls.length, 1);
    await waitForCacheEntry(cache, sentenceB);
  });

  test('预取失败进入冷却，冷却期内不再重试同一句', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    // 两次调用（预取一次、面板一次）各要一个响应。
    endpoint.responses['$langId|$sentenceB'] = [
      () => errorStream('rate'),
      () => errorStream('rate'),
    ];

    final notifier = container.read(sentenceAiProvider.notifier);
    notifier.schedulePrefetch(upcoming: [sentenceB], langId: langId);
    await waitForEndpointCalls(endpoint, 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 冷却 60s，远长于测试时长：第二次调度不应再发请求。
    notifier.schedulePrefetch(upcoming: [sentenceB], langId: langId);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(endpoint.calls.length, 1);

    // 但用户主动打开面板仍然会真的请求（冷却只限制预取）。
    await notifier.analyze(sentence: sentenceB, langId: langId);
    await waitForState(container, (s) => s.status == SentenceAiStatus.error);
    expect(endpoint.calls.length, 2);
    expect(await cache.getFromCache(
      AiAnalysisCacheService.cacheKey(langId, sentenceB),
    ), isNull);
  });

  test('unsupported 语言的预取当场熔断，后续调度直接跳过', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    endpoint.responses['$langId|$sentenceB'] = [() => errorStream('unsupported')];
    endpoint.responses['$langId|$sentenceC'] = [() => okStream(resultOf('C'))];

    final notifier = container.read(sentenceAiProvider.notifier);
    notifier.schedulePrefetch(
      upcoming: [sentenceB, sentenceC],
      langId: langId,
    );
    await waitForEndpointCalls(endpoint, 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // B 报 unsupported 后，队列里的 C 也不再请求。
    expect(endpoint.calls, ['$langId|$sentenceB']);

    // 之后的调度在进 timer 前就被跳过。
    notifier.schedulePrefetch(
      upcoming: [sentenceB, sentenceC],
      langId: langId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(endpoint.calls, ['$langId|$sentenceB']);
  });

  test('schedulePrefetch 对空文本/空列表不安排任何请求', () async {
    final (:container, :endpoint, :cache) = makeContainer();

    final notifier = container.read(sentenceAiProvider.notifier);
    notifier.schedulePrefetch(upcoming: ['  ', ''], langId: langId);
    notifier.schedulePrefetch(upcoming: [], langId: langId);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(endpoint.calls, isEmpty);
    expect(await cache.getCacheStats(), isA<Map<String, dynamic>>());
  });

  // 整本离线下载拉回的解释按服务端切句存，Sentence Reader 的「句子合并」
  // 会把相邻短句拼成一句。精确 key miss 时要能按片段把解释拼回来。
  const partA = 'あ、やっとつながった。';
  const partB = '今日はどうしたんですか。';
  const combined = 'あ、やっとつながった。 今日はどうしたんですか。';

  test('合并句按片段拼回已缓存的解释，不发网络请求', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    await cache.saveToCache(
      key: AiAnalysisCacheService.cacheKey(langId, partA),
      result: resultOf('A 译').toJson(),
    );
    await cache.saveToCache(
      key: AiAnalysisCacheService.cacheKey(langId, partB),
      result: resultOf('B 译').toJson(),
    );

    await container.read(sentenceAiProvider.notifier).analyze(
          sentence: combined,
          langId: langId,
        );
    final state = await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done,
    );
    expect(state.result?.translation, 'A 译\nB 译');
    expect(state.result?.segments, hasLength(2));
    expect(state.meta?.cached, isTrue);
    expect(endpoint.calls, isEmpty);
  });

  test('只命中一个片段也照常展示，不因缺片段退回网络', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    await cache.saveToCache(
      key: AiAnalysisCacheService.cacheKey(langId, partA),
      result: resultOf('A 译').toJson(),
    );

    await container.read(sentenceAiProvider.notifier).analyze(
          sentence: combined,
          langId: langId,
        );
    final state = await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done,
    );
    expect(state.result?.translation, 'A 译');
    expect(endpoint.calls, isEmpty);
  });

  test('片段回退也认升级前的 legacy key', () async {
    final (:container, :endpoint, :cache) = makeContainer();
    await cache.saveToCache(
      key: AiAnalysisCacheService.legacyCacheKey(langId, partA),
      fallbackText: '旧版译文',
    );

    await container.read(sentenceAiProvider.notifier).analyze(
          sentence: combined,
          langId: langId,
        );
    final state = await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done,
    );
    expect(state.fallbackText, '旧版译文');
    expect(endpoint.calls, isEmpty);
  });

  test('单句 miss 仍走网络，片段回退不会吞掉正常请求', () async {
    final setup = makeContainer();
    final container = setup.container;
    final endpoint = setup.endpoint;
    endpoint.responses['$langId|$sentenceA'] = [() => okStream(resultOf('A'))];

    await container.read(sentenceAiProvider.notifier).analyze(
          sentence: sentenceA,
          langId: langId,
        );
    await waitForState(
      container,
      (s) => s.status == SentenceAiStatus.done && s.result?.translation == 'A',
    );
    expect(endpoint.calls, ['$langId|$sentenceA']);
  });
}

/// 面板/预取把结果写进缓存是异步的：等条目真正出现再继续，否则下一个
/// 断言可能读到 miss 造成 flaky。
Future<void> waitForCacheEntry(
  AiAnalysisCacheService cache,
  String sentence, {
  int langId = 7,
}) async {
  final key = AiAnalysisCacheService.cacheKey(langId, sentence);
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (await cache.getFromCache(key) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('cache entry for "$sentence" never appeared');
}
