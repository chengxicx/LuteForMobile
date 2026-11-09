import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/ai_analysis_cache_service.dart';
import '../../../core/cache/providers/ai_analysis_cache_provider.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/sentence_ai_result.dart';
import '../services/offline_sentence_ai_lookup.dart';

/// 词卡「Sentence」面板里 `/ai/sentence` 那一页的**离线替身**。
///
/// 在线时那一页是 WebView 直接渲染服务端网页；断网时 WebView 只会弹
/// `net::ERR_INTERNET_DISCONNECTED`。这里不发任何请求，改用整本下载拉回
/// 的 `sentence_ai_cache`，把结构化结果用 Flutter 画出来。
///
/// 刻意不复用 [SentenceAITranslationWidget]：那个面板带自己的 header、
/// 关闭按钮，还共用全局 `sentenceAiProvider`；塞进 PageView 的一页会互相
/// 抢状态。这里只读缓存、纯展示。
class OfflineSentenceAiView extends ConsumerStatefulWidget {
  final String sentence;
  final int languageId;

  /// 「重试联网」：调用方清掉失败标记并重建 WebView。
  final VoidCallback onRetry;

  const OfflineSentenceAiView({
    super.key,
    required this.sentence,
    required this.languageId,
    required this.onRetry,
  });

  @override
  ConsumerState<OfflineSentenceAiView> createState() =>
      _OfflineSentenceAiViewState();
}

class _OfflineSentenceAiViewState
    extends ConsumerState<OfflineSentenceAiView> {
  late Future<AiAnalysisCacheEntry?> _future;

  @override
  void initState() {
    super.initState();
    _future = _lookup();
  }

  @override
  void didUpdateWidget(covariant OfflineSentenceAiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sentence != widget.sentence ||
        oldWidget.languageId != widget.languageId) {
      _future = _lookup();
    }
  }

  Future<AiAnalysisCacheEntry?> _lookup() => lookupOfflineSentenceAi(
        cache: ref.read(sentenceAiCacheServiceProvider),
        langId: widget.languageId,
        sentence: widget.sentence,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AiAnalysisCacheEntry?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final entry = snapshot.data;
        SentenceAiResult? result;
        if (entry?.result != null) {
          final parsed = SentenceAiResult.fromJson(entry!.result!);
          if (!parsed.isEmpty) result = parsed;
        }
        final fallback = entry?.fallbackText?.trim();
        final hasFallback = fallback != null && fallback.isNotEmpty;
        if (result == null && !hasFallback) {
          return _buildEmpty(context, hasError: snapshot.hasError);
        }
        return _buildContent(context, result, hasFallback ? fallback : null);
      },
    );
  }

  Widget _buildEmpty(BuildContext context, {required bool hasError}) {
    final scheme = context.appColorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _badge(context),
          const SizedBox(height: 18),
          Icon(Icons.cloud_off_outlined, size: 40,
              color: scheme.text.secondary),
          const SizedBox(height: 12),
          Text(
            '这句没有离线解释',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.text.primary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            hasError
                ? '读取本地缓存时出错了，可以重试联网查看。'
                : '联网打开一次这句的解释，或在书架长按这本书，\n'
                    '勾选下载 AI 解释后即可离线使用。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.text.secondary,
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: widget.onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试联网'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    SentenceAiResult? result,
    String? fallback,
  ) {
    final scheme = context.appColorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.text.primary,
          height: 1.5,
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _badge(context),
          const SizedBox(height: 14),
          _sectionLabel(context, 'Original Sentence'),
          const SizedBox(height: 6),
          Text(widget.sentence, style: textStyle),
          if (result?.translation != null || fallback != null) ...[
            const SizedBox(height: 18),
            _sectionLabel(context, 'Translation'),
            const SizedBox(height: 6),
            Text(
              result?.translation ?? fallback!,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.text.primary,
                    height: 1.55,
                  ),
            ),
          ],
          if (result != null && result.segments.isNotEmpty) ...[
            const SizedBox(height: 18),
            _sectionLabel(context, 'Word by word'),
            const SizedBox(height: 6),
            for (final seg in result.segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  [
                    if (seg.part != null) seg.part!,
                    if (seg.reading != null) '（${seg.reading}）',
                    if (seg.meaning != null) ' — ${seg.meaning}',
                    if (seg.role != null) ' [${seg.role}]',
                  ].join(),
                  style: textStyle,
                ),
              ),
          ],
          if (result != null && result.grammar.isNotEmpty) ...[
            const SizedBox(height: 18),
            _sectionLabel(context, 'Grammar'),
            const SizedBox(height: 6),
            for (final g in result.grammar)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  [
                    if (g.point != null) g.point!,
                    if (g.explanation != null) '：${g.explanation}',
                    if (g.fragment != null) '（${g.fragment}）',
                  ].join(),
                  style: textStyle,
                ),
              ),
          ],
          if (result?.context != null) ...[
            const SizedBox(height: 18),
            _sectionLabel(context, 'Context'),
            const SizedBox(height: 6),
            Text(result!.context!, style: textStyle),
          ],
          if (result != null && result.examples.isNotEmpty) ...[
            const SizedBox(height: 18),
            _sectionLabel(context, 'Examples'),
            const SizedBox(height: 6),
            for (final ex in result.examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  [
                    if (ex.source != null) ex.source!,
                    if (ex.translation != null) '\n${ex.translation}',
                  ].join(),
                  style: textStyle,
                ),
              ),
          ],
          const SizedBox(height: 20),
          Text(
            '来自整本下载的本地缓存；联网打开可刷新为整句完整解释。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.text.secondary,
                ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('联网刷新'),
          ),
        ],
      ),
    );
  }

  Widget _badge(BuildContext context) {
    final scheme = context.appColorScheme;
    return Row(
      children: [
        Icon(Icons.cloud_off_outlined,
            size: 16, color: scheme.text.secondary),
        const SizedBox(width: 6),
        Text(
          '离线结果 · 本地缓存',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.text.secondary,
              ),
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: context.m3Primary,
            fontWeight: FontWeight.bold,
          ),
    );
  }
}
