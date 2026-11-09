import '../../../core/cache/ai_analysis_cache_service.dart';
import '../utils/sentence_fragments.dart';

/// 只读本地缓存地找一句 AI 句子解释。
///
/// 整本离线下载把服务端 `/ai/library/export` 的结果按「规范化后的单句」
/// 写进 `sentence_ai_cache`；阅读页实际拿到的句子可能带零宽空格、全角
/// 空格，甚至被「句子合并」拼成一大段。这里把「精确 → legacy → 片段」
/// 三级查找集中到一处，Sentence Reader 的 Flutter 面板和词卡的
/// WebView 面板共用，避免两边 key 规则各写一份后悄悄漂移。

/// 精确 key；升级前写入的条目用 legacy key 再兜一次。
Future<AiAnalysisCacheEntry?> lookupExactCachedSentenceAi({
  required AiAnalysisCacheService cache,
  required int langId,
  required String sentence,
}) async {
  var entry = await cache.getFromCache(
    AiAnalysisCacheService.cacheKey(langId, sentence),
  );
  entry ??= await cache.getFromCache(
    AiAnalysisCacheService.legacyCacheKey(langId, sentence),
  );
  return entry;
}

/// 合并句的片段回退：逐段查缓存，命中的结果拼成一份条目。
///
/// 只命中部分片段也照常返回 —— 断网时「有几段译文」远好过整页报错；
/// 一段都没命中才返回 null，交回原来的联网路径。
Future<AiAnalysisCacheEntry?> composeCachedSentenceAiFragments({
  required AiAnalysisCacheService cache,
  required int langId,
  required String sentence,
}) async {
  final parts = splitCombinedSentence(sentence);
  if (parts.isEmpty) return null;

  final results = <Map<String, dynamic>>[];
  final fallbacks = <String>[];
  AiAnalysisCacheEntry? first;
  for (final part in parts) {
    final entry = await lookupExactCachedSentenceAi(
      cache: cache,
      langId: langId,
      sentence: part,
    );
    if (entry == null) continue;
    first ??= entry;
    final result = entry.result;
    if (result != null) results.add(result);
    final fallback = entry.fallbackText?.trim();
    if (fallback != null && fallback.isNotEmpty) fallbacks.add(fallback);
  }
  if (first == null) return null;

  final merged = mergeSentenceAiResults(results);
  final fallbackText = fallbacks.isEmpty ? null : fallbacks.join('\n');
  if (merged.isEmpty && fallbackText == null) return null;

  // 拼出来的条目没有单一 key 可比，不参与后台服务端比对；面板按
  // cached 展示，用户想拿整句完整解释可以联网刷新。
  return AiAnalysisCacheEntry(
    timestamp: first.timestamp,
    sizeInBytes: 0,
    result: merged.isEmpty ? null : merged,
    fallbackText: fallbackText,
    provider: first.provider,
    model: first.model,
  );
}

/// 词卡 WebView 面板离线时用的完整查找。
Future<AiAnalysisCacheEntry?> lookupOfflineSentenceAi({
  required AiAnalysisCacheService cache,
  required int langId,
  required String sentence,
}) async {
  final exact = await lookupExactCachedSentenceAi(
    cache: cache,
    langId: langId,
    sentence: sentence,
  );
  if (exact != null) return exact;
  return composeCachedSentenceAiFragments(
    cache: cache,
    langId: langId,
    sentence: sentence,
  );
}
