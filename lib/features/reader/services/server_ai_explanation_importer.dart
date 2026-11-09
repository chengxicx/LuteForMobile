import '../../../core/cache/ai_analysis_cache_service.dart';

/// 服务端整本书的 AI 解释导出（GET `/ai/library/export`）。
/// 返回 null 表示拿不到：断网、未登录、或老服务端还没有这个路由。
typedef AiExplanationExportFetch =
    Future<Map<String, dynamic>?> Function(int bookId);

/// 把服务端**已经存下**的解释搬进本地 AI 缓存，并标成 pinned 离线资产。
///
/// 服务端把句子解释持久化在 `airesults` 表里（Web 端预取、导入、面板
/// 命中都会落库），导出接口只是读库，不触发任何 LLM 调用。整本离线下载
/// 勾选 AI 解释时调一次，之后断网打开句子面板就能直接命中本地缓存。
///
/// 与「只 pin 本地已有解释」的旧行为不同：这里会主动把服务器上这本书
/// 攒下的解释拉回来，用户不需要联网时逐句点开过。
class ServerAiExplanationImporter {
  ServerAiExplanationImporter({
    required AiExplanationExportFetch fetch,
    required AiAnalysisCacheService cache,
  }) : _fetch = fetch,
       _cache = cache;

  final AiExplanationExportFetch _fetch;
  final AiAnalysisCacheService _cache;

  /// 返回实际落盘的条数。任何失败都返回 0 —— 拉不到解释绝不能让整本
  /// 离线下载失败，调用方会退回「只保留本地已有解释」的旧行为。
  Future<int> importForBook(int bookId) async {
    final Map<String, dynamic>? payload;
    try {
      payload = await _fetch(bookId);
    } catch (_) {
      return 0;
    }
    if (payload == null) return 0;

    final items = payload['items'];
    if (items is! List) return 0;
    // 导出时没带 lang_id 参数的话，服务端会填 book.language_id。
    final langId = (payload['lang_id'] as num?)?.toInt();
    if (langId == null) return 0;
    final rawModel = payload['model'] as String?;
    final model = (rawModel == null || rawModel == 'mixed') ? null : rawModel;

    var saved = 0;
    for (final item in items) {
      if (item is! Map) continue;
      // 语法面板的结果结构与句译不同，这里只搬句译（"AI 句子解释"）。
      final kind = item['kind'] as String?;
      if (kind != null && kind != 'sentence') continue;
      final sentence = item['sentence'] is String
          ? item['sentence'] as String
          : '';
      if (sentence.trim().isEmpty) continue;

      // 导出格式把结果字段摊平在 item 里，去掉三个元数据键就是
      // SentenceAiResult.fromJson 要的那份 JSON。
      final result = Map<String, dynamic>.from(item)
        ..remove('sentence')
        ..remove('kind')
        ..remove('target_lang');
      if (result.isEmpty) continue;

      final ok = await _cache.saveToCache(
        key: AiAnalysisCacheService.cacheKey(langId, sentence),
        result: result,
        model: model,
        pinned: true,
        bookId: bookId,
        // 几百条逐条跑体积淘汰是 O(n²)；这些全是 pinned 条目，本来也
        // 不计入可淘汰体积，下一次普通写入会统一收尾。
        enforceSizeLimit: false,
      );
      if (ok) saved++;
    }
    return saved;
  }
}
