import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/providers/network_providers.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../models/sentence_ai_result.dart';
import '../providers/sentence_ai_provider.dart';
import '../providers/sentence_tts_provider.dart';

class SentenceAITranslationWidget extends ConsumerStatefulWidget {
  final String sentence;
  final int languageId;
  final VoidCallback onClose;
  final int? sentenceId;

  const SentenceAITranslationWidget({
    super.key,
    required this.sentence,
    required this.languageId,
    required this.onClose,
    this.sentenceId,
  });

  @override
  ConsumerState<SentenceAITranslationWidget> createState() =>
      _SentenceAITranslationWidgetState();
}

class _SentenceAITranslationWidgetState
    extends ConsumerState<SentenceAITranslationWidget> {
  /// 服务端先回 meta（常常带 cache 标记）、正文帧却卡住时，界面以前是纯空白：
  /// 用户既不知道在等什么，也没有重试入口。给「多久没动静算卡住」一个阈值，
  /// 到点才出现 Retry —— 正常几秒的等待不该先弹重试。
  static const Duration _stallTimeout = Duration(seconds: 10);

  Timer? _stallTimer;
  bool _stalled = false;
  bool _originalExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(sentenceAiProvider.notifier)
          .ensureAnalyzed(
            sentence: widget.sentence,
            langId: widget.languageId,
          );
      // meta 可能比本 widget 先到（缓存命中的路径），listen 不会补发旧状态，
      // 所以这里也武装一次。
      _armStallTimer(ref.read(sentenceAiProvider));
    });
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    super.dispose();
  }

  /// 只有「在等、且还没有一个字」的阶段才需要卡住检测；正文开始流出或已经
  /// 完成就把计时收掉。
  void _armStallTimer(SentenceAiState state) {
    _stallTimer?.cancel();
    final waiting =
        (state.isWaiting && state.streamedText.trim().isEmpty) ||
        !_belongs(state);
    if (!waiting) {
      if (_stalled) _stalled = false;
      return;
    }
    _stallTimer = Timer(_stallTimeout, () {
      if (!mounted) return;
      setState(() => _stalled = true);
    });
  }

  bool _belongs(SentenceAiState state) =>
      state.sentence == widget.sentence && state.langId == widget.languageId;

  void _retry() {
    _stalled = false;
    _armStallTimer(ref.read(sentenceAiProvider));
    ref
        .read(sentenceAiProvider.notifier)
        .analyze(
          sentence: widget.sentence,
          langId: widget.languageId,
          // A retry asks for a fresh answer; the cache-first path would just
          // re-serve the cached payload again.
          forceNetwork: true,
        );
  }

  Future<void> _openWebSettings() async {
    final base = ref.read(apiServiceProvider).baseUrl.trim();
    if (base.isEmpty) return;
    final root = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    try {
      await launchUrl(
        Uri.parse('$root/settings/index'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // The error copy still tells the user where to configure the provider.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        minHeight: 200,
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.appColorScheme.background.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 12),
          Expanded(child: _buildContent(context)),
          const SizedBox(height: 12),
          _buildActions(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final ttsState = ref.watch(sentenceTTSProvider);
    final errorColor = context.appColorScheme.error.error;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ttsState.hasError && ttsState.errorMessage != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ttsState.errorMessage!),
            backgroundColor: errorColor,
            action: SnackBarAction(
              label: 'Retry',
              textColor: context.appColorScheme.error.onError,
              onPressed: () {
                ref.read(sentenceTTSProvider.notifier).clearError();
                ref
                    .read(sentenceTTSProvider.notifier)
                    .speakSentence(widget.sentence, widget.sentenceId ?? 0);
              },
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });

    IconData ttsIcon;
    Color ttsColor;
    VoidCallback? ttsOnPressed;

    switch (ttsState.status) {
      case SentenceTTSStatus.playing:
        ttsIcon = Icons.stop;
        ttsColor = errorColor;
        ttsOnPressed = () => ref.read(sentenceTTSProvider.notifier).stop();
        break;
      case SentenceTTSStatus.error:
        ttsIcon = Icons.refresh;
        ttsColor = errorColor;
        ttsOnPressed = () {
          ref.read(sentenceTTSProvider.notifier).clearError();
          ref
              .read(sentenceTTSProvider.notifier)
              .speakSentence(widget.sentence, widget.sentenceId ?? 0);
        };
        break;
      case SentenceTTSStatus.loading:
        ttsIcon = Icons.hourglass_empty;
        ttsColor = context.appColorScheme.material3.primary;
        ttsOnPressed = null;
        break;
      case SentenceTTSStatus.idle:
        ttsIcon = Icons.volume_up;
        ttsColor = context.appColorScheme.material3.primary;
        ttsOnPressed = () => ref
            .read(sentenceTTSProvider.notifier)
            .speakSentence(widget.sentence, widget.sentenceId ?? 0);
        break;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'AI Translation',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        IconButton(
          icon: Icon(ttsIcon),
          color: ttsColor,
          onPressed: ttsOnPressed,
          tooltip: _getTTSTooltip(ttsState.status),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final state = ref.watch(sentenceAiProvider);
    // 状态每次变化都重估卡住计时：正文开始流出、或已经完成，就把它收掉。
    ref.listen<SentenceAiState>(sentenceAiProvider, (_, next) {
      _armStallTimer(next);
    });
    final belongs = _belongs(state);

    if (belongs &&
        state.status == SentenceAiStatus.error &&
        state.errorMessage != null) {
      return _ErrorView(
        kind: state.errorKind,
        message: state.errorMessage!,
        detail: state.errorDetail,
        onRetry: _retry,
        onOpenWebSettings:
            state.errorKind == 'unconfigured' ? _openWebSettings : null,
      );
    }

    if (!belongs || state.isWaiting) {
      final streamed = belongs ? state.streamedText.trim() : '';
      if (streamed.isNotEmpty) return _StreamView(text: streamed);
      // 以前 meta 带 cache 标记时这里直接 `SizedBox.shrink()`：弱网下服务端
      // 先回 meta、正文帧卡住，整个面板就是一片空白 —— 既看不出在等什么，
      // 也没有重试入口。现在始终说明"在等什么"，卡住超时后再给 Retry。
      return _WaitingView(
        cached: belongs && state.isCached,
        stalled: _stalled,
        onRetry: _retry,
      );
    }

    final result = state.result;
    final fallback = state.fallbackText?.trim();
    final hasFallback = fallback != null && fallback.isNotEmpty;
    if ((result == null || result.isEmpty) && !hasFallback) {
      return const Center(child: Text('The AI returned no result.'));
    }

    final translation = result?.translation ?? (hasFallback ? fallback : null);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            initiallyExpanded: _originalExpanded,
            onExpansionChanged: (expanded) {
              setState(() => _originalExpanded = expanded);
            },
            title: Text(
              'Original Sentence',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(
              top: 8,
              left: 12,
              right: 12,
              bottom: 8,
            ),
            children: [
              Text(
                widget.sentence,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 缓存是永久的，但服务端可能已经给出不同结果（换模型 / 服务端
          // 缓存被清后重算）。这里只提示，不擅自替换用户正在读的内容。
          if (state.serverUpdateAvailable) ...[
            _ServerUpdateNotice(
              onRefresh: () => ref
                  .read(sentenceAiProvider.notifier)
                  .analyze(
                    sentence: widget.sentence,
                    langId: widget.languageId,
                    forceNetwork: true,
                  ),
            ),
            const SizedBox(height: 8),
          ],
          if (translation != null && translation.isNotEmpty)
            _TranslationCard(text: translation),
          if (result != null) ...[
            if (result.segments.isNotEmpty)
              _SectionCard(
                icon: Icons.view_list_outlined,
                title: 'Word by word',
                child: _SegmentList(segments: result.segments),
              ),
            if (result.grammar.isNotEmpty)
              _SectionCard(
                icon: Icons.spellcheck,
                title: 'Grammar points',
                child: _GrammarList(items: result.grammar),
              ),
            if (result.context != null)
              _SectionCard(
                icon: Icons.subject,
                title: 'Context',
                child: Text(
                  result.context!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            if (result.examples.isNotEmpty)
              _SectionCard(
                icon: Icons.menu_book_outlined,
                title: 'Examples',
                child: _ExampleList(examples: result.examples),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final state = ref.watch(sentenceAiProvider);
    if (state.status != SentenceAiStatus.done) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: widget.onClose,
        icon: const Icon(Icons.close),
        label: const Text('Close'),
      ),
    );
  }

  String _getTTSTooltip(SentenceTTSStatus status) {
    switch (status) {
      case SentenceTTSStatus.playing:
        return 'Stop';
      case SentenceTTSStatus.error:
        return 'Retry';
      case SentenceTTSStatus.loading:
        return 'Loading';
      case SentenceTTSStatus.idle:
        return 'Play';
    }
  }
}

/// 「服务端结果有更新」的提示条。
///
/// 缓存改永久之后不能静默用旧值：比对发现服务端现有答案与本地不一致时
/// 才出现，刷新是显式动作（重新走一次流式请求并覆盖缓存）。
class _ServerUpdateNotice extends StatelessWidget {
  final VoidCallback onRefresh;

  const _ServerUpdateNotice({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: context.eInk
            ? colors.background.surface
            : context.m3SecondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: context.eInk
            ? Border.all(color: colors.border.outline, width: 1.5)
            : null,
      ),
      child: Row(
        children: [
          Icon(
            Icons.sync_problem_outlined,
            size: 18,
            color: context.m3Secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The server has a newer version of this explanation.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: onRefresh,
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

class _TranslationCard extends StatelessWidget {
  final String text;

  const _TranslationCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: context.eInk
            ? colors.background.surface
            : context.m3PrimaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: context.eInk
            ? Border.all(color: colors.border.outline, width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.translate, size: 15, color: colors.text.secondary),
              const SizedBox(width: 5),
              Text(
                'Translation',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.text.secondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        border: context.eInk
            ? Border.all(color: colors.border.outline, width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.text.secondary),
              const SizedBox(width: 6),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _SegmentList extends StatelessWidget {
  final List<SentenceAiSegment> segments;

  const _SegmentList({required this.segments});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < segments.length; i++)
          _SegmentRow(segment: segments[i], last: i == segments.length - 1),
      ],
    );
  }
}

class _SegmentRow extends StatelessWidget {
  final SentenceAiSegment segment;
  final bool last;

  const _SegmentRow({required this.segment, required this.last});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      margin: EdgeInsets.only(bottom: last ? 0 : 12),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.border.outline.withValues(alpha: 0.35),
                ),
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (segment.part != null)
                Text(
                  segment.part!,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (segment.reading != null)
                Text(
                  segment.reading!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.text.secondary,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              if (segment.role != null) _RolePill(text: segment.role!),
            ],
          ),
          if (segment.meaning != null) ...[
            const SizedBox(height: 5),
            Text(
              segment.meaning!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String text;

  const _RolePill({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.background.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.text.secondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GrammarList extends StatelessWidget {
  final List<SentenceAiGrammar> items;

  const _GrammarList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          _GrammarRow(item: items[i], last: i == items.length - 1),
      ],
    );
  }
}

class _GrammarRow extends StatelessWidget {
  final SentenceAiGrammar item;
  final bool last;

  const _GrammarRow({required this.item, required this.last});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.point != null)
            Text(
              item.point!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          if (item.explanation != null) ...[
            const SizedBox(height: 3),
            Text(
              item.explanation!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (item.fragment != null) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
              decoration: BoxDecoration(
                border: BorderDirectional(
                  start: BorderSide(
                    color: context.eInk
                        ? colors.text.primary
                        : context.m3Primary,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                item.fragment!,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExampleList extends StatelessWidget {
  final List<SentenceAiExample> examples;

  const _ExampleList({required this.examples});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < examples.length; i++)
          _ExampleRow(example: examples[i], last: i == examples.length - 1),
      ],
    );
  }
}

class _ExampleRow extends StatelessWidget {
  final SentenceAiExample example;
  final bool last;

  const _ExampleRow({required this.example, required this.last});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (example.source != null)
            Text(
              example.source!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          if (example.translation != null) ...[
            const SizedBox(height: 2),
            Text(
              example.translation!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.text.secondary,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 等待 AI 正文时的可见状态。
///
/// 弱网下最糟的一种是「服务端回了 meta（还标着 cache 命中），正文帧却一直
/// 不到」—— 这种时候必须让用户看到还在等，并在真的卡住之后给一个重试入口。
class _WaitingView extends StatelessWidget {
  final bool cached;
  final bool stalled;
  final VoidCallback onRetry;

  const _WaitingView({
    required this.cached,
    required this.stalled,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    if (!stalled) {
      return LoadingIndicator(
        message: cached
            ? 'Loaded from cache · preparing answer...'
            : 'Analyzing sentence...',
      );
    }
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.hourglass_empty, size: 40, color: colors.text.secondary),
          const SizedBox(height: 12),
          Text(
            cached
                ? 'The cached answer is not arriving yet.'
                : 'The AI answer is not arriving yet.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'The connection may be weak. You can retry, or close this panel '
            'and keep reading.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.text.secondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _StreamView extends StatelessWidget {
  final String text;

  const _StreamView({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        border: context.eInk
            ? Border.all(color: colors.border.outline, width: 1)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: colors.text.secondary),
              const SizedBox(width: 6),
              Text(
                'Live output',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.text.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String? kind;
  final String message;
  final String? detail;
  final VoidCallback onRetry;
  final VoidCallback? onOpenWebSettings;

  const _ErrorView({
    required this.kind,
    required this.message,
    this.detail,
    required this.onRetry,
    this.onOpenWebSettings,
  });

  String get _title {
    switch (kind) {
      case 'unconfigured':
        return 'AI not configured';
      case 'unsupported':
        return 'AI is turned off for this language';
      case 'auth':
        return 'AI authentication failed';
      case 'rate':
        return 'AI provider is busy';
      case 'timeout':
        return 'AI request timed out';
      case 'offline':
        return 'No network connection';
      case 'login':
        return 'Session expired';
      default:
        return 'AI request failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          Icon(Icons.error_outline, size: 44, color: context.error),
          const SizedBox(height: 12),
          Text(_title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.45),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
              if (onOpenWebSettings != null)
                ElevatedButton.icon(
                  onPressed: onOpenWebSettings,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open web settings'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
