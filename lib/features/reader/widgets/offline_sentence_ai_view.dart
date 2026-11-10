import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/ai_analysis_cache_service.dart';
import '../../../core/cache/providers/ai_analysis_cache_provider.dart';
import '../../../core/network/dictionary_service.dart';
import '../models/sentence_ai_result.dart';
import '../services/offline_sentence_ai_lookup.dart';
import 'offline_sentence_ai_html.dart';

/// 词卡「Sentence」面板里 `/ai/sentence` 那一页的**离线替身**。
///
/// 在线时那一页是 WebView 直接渲染服务端网页；断网时 WebView 只会弹
/// `net::ERR_INTERNET_DISCONNECTED`。这里改成用**同一个 WebView** 渲染一份
/// 本地 HTML：页面骨架、CSS、结果渲染函数都来自服务端 `ai/sentence.html`，
/// 数据换成整本下载拉回的 `sentence_ai_cache`。因此离线与联网的排版、
/// 字号、表格、主题配色一致，区别只剩 eyebrow 上的状态标记。
///
/// 刻意不复用 [SentenceAITranslationWidget]：那个面板带自己的 header、
/// 关闭按钮，还共用全局 `sentenceAiProvider`；塞进 PageView 的一页会互相
/// 抢状态。这里只读缓存、纯展示。
class OfflineSentenceAiView extends ConsumerStatefulWidget {
  final String sentence;
  final int languageId;

  /// 与在线页完全相同的 App 主题 CSS（见
  /// [DictionaryService.serverPageThemeCss]），由调用方算好后传入。
  final String themeCss;

  /// 「重试联网」：调用方清掉失败标记并重建 WebView。
  final VoidCallback onRetry;

  /// 把 controller 交给调用方，切回这一页时才能和在线 WebView 一样强制重画
  /// （BOOX 墨水屏上 platform view 复贴后不重绘会整页空白）。
  final void Function(InAppWebViewController controller)? onControllerCreated;

  const OfflineSentenceAiView({
    super.key,
    required this.sentence,
    required this.languageId,
    required this.themeCss,
    required this.onRetry,
    this.onControllerCreated,
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
        Map<String, dynamic>? result = entry?.result;
        if (result != null && SentenceAiResult.fromJson(result).isEmpty) {
          result = null;
        }
        final fallback = entry?.fallbackText?.trim();
        final hasFallback = fallback != null && fallback.isNotEmpty;
        final hasContent = result != null || hasFallback;
        final provider = entry?.provider?.trim();
        final model = entry?.model?.trim();

        final html = buildOfflineSentenceAiHtml(
          sentence: widget.sentence,
          result: result,
          fallbackText: result == null && hasFallback ? fallback : null,
          themeCss: widget.themeCss,
          providerLabel: (provider != null && provider.isNotEmpty)
              ? provider
              : (model != null && model.isNotEmpty ? model : 'Local cache'),
          badgeLabel: hasContent ? 'Cached' : 'Offline',
          hasContent: hasContent,
          emptyMessage: snapshot.hasError
              ? '读取本地缓存时出错了，点 Retry 联网查看。'
              : '这句没有离线解释。联网打开一次，或在书架长按这本书、'
                  '勾选下载 AI 解释后重新下载。',
        );

        return InAppWebView(
          initialSettings: DictionaryService.webviewSettings(
            localDictionary: false,
          ),
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory(() => VerticalDragGestureRecognizer()),
          },
          onWebViewCreated: (controller) {
            widget.onControllerCreated?.call(controller);
            controller.addJavaScriptHandler(
              handlerName: 'retryOnline',
              callback: (args) {
                widget.onRetry();
                return null;
              },
            );
            unawaited(
              controller.loadData(
                data: html,
                baseUrl: WebUri('about:blank'),
              ),
            );
          },
        );
      },
    );
  }
}
