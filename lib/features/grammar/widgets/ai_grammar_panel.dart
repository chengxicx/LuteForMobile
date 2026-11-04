import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/providers/network_providers.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/ai_grammar_result.dart';
import '../providers/ai_grammar_provider.dart';
import 'sentence_quote_header.dart';

/// AI grammar analysis of one sentence, streamed from
/// `POST /ai/grammar/analyze`.
///
/// This is deliberately a sibling of the local grammar library, not a
/// replacement: the local tab answers from the server's rule/dictionary
/// library, this tab asks the server's configured AI provider.
class AiGrammarPanel extends ConsumerStatefulWidget {
  final String sentence;
  final int? langId;
  final bool active;

  const AiGrammarPanel({
    super.key,
    required this.sentence,
    required this.langId,
    required this.active,
  });

  @override
  ConsumerState<AiGrammarPanel> createState() => _AiGrammarPanelState();
}

class _AiGrammarPanelState extends ConsumerState<AiGrammarPanel> {
  @override
  void initState() {
    super.initState();
    _startIfActive();
  }

  @override
  void didUpdateWidget(AiGrammarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        (!oldWidget.active ||
            oldWidget.sentence != widget.sentence ||
            oldWidget.langId != widget.langId)) {
      _startIfActive();
    }
  }

  void _startIfActive() {
    final langId = widget.langId;
    if (!widget.active || langId == null) return;
    // The parent may be in the middle of building the TabBarView; starting a
    // request from a post-frame callback keeps provider writes out of build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(aiGrammarProvider.notifier)
          .ensureAnalyzed(sentence: widget.sentence, langId: langId);
    });
  }

  void _retry() {
    final langId = widget.langId;
    if (langId == null) return;
    ref
        .read(aiGrammarProvider.notifier)
        .analyze(sentence: widget.sentence, langId: langId);
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
      // Nothing to fall back to: the button is only a convenience.
    }
  }

  @override
  Widget build(BuildContext context) {
    final langId = widget.langId;
    if (langId == null) {
      return _buildMessage(
        context,
        icon: Icons.translate,
        title: 'Language not detected',
        message:
            'The sentence has no language id, so AI analysis cannot start. '
            'Open the book, tap a word, and try again.',
      );
    }

    final state = ref.watch(aiGrammarProvider);
    final belongs =
        state.sentence == widget.sentence && state.langId == langId;

    if (!widget.active) {
      return _buildMessage(
        context,
        icon: Icons.auto_awesome,
        title: 'AI analysis',
        message: 'Switch to the AI tab to analyze this sentence.',
      );
    }

    if (!belongs) {
      return _buildWaiting(context, null);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // The whole-sentence translation is the first thing the panel shows.
        // Missing translation means no block at all -- never an empty line.
        if (state.result?.translation != null) ...[
          _TranslationCard(translation: state.result!.translation!),
          const SizedBox(height: 12),
        ],
        SentenceQuoteHeader(sentence: widget.sentence),
        const SizedBox(height: 10),
        if (state.meta != null) _MetaLine(meta: state.meta!),
        if (state.status == AiGrammarStatus.error && state.errorMessage != null)
          _AiErrorCard(
            kind: state.errorKind,
            message: state.errorMessage!,
            detail: state.errorDetail,
            onRetry: _retry,
            onOpenWebSettings:
                state.errorKind == 'unconfigured' ? _openWebSettings : null,
          )
        else if (state.isWaiting)
          _buildWaiting(context, state)
        else ...[
          if (state.hasStructuredResult)
            ..._buildResult(context, state.result!),
          if (state.fallbackText != null && state.fallbackText!.isNotEmpty)
            _FallbackCard(text: state.fallbackText!),
          if (!state.hasStructuredResult &&
              (state.fallbackText == null || state.fallbackText!.isEmpty))
            _buildMessage(
              context,
              icon: Icons.spellcheck,
              title: 'No AI result',
              message: 'The AI returned an empty analysis.',
            ),
        ],
      ],
    );
  }

  Widget _buildWaiting(BuildContext context, AiGrammarState? state) {
    final streamed = state?.streamedText.trim() ?? '';
    if (streamed.isEmpty) {
      // A cached answer is already on the server and arrives without any
      // generation delay; the meta line's "Cached" chip is the only feedback
      // needed, so do not flash a loading block for it.
      if (state?.isCached == true) return const SizedBox(height: 4);
      return SizedBox(
        height: 220,
        child: Center(child: _LoadingBlock(message: 'Analyzing with AI…')),
      );
    }
    return _StreamPreview(text: streamed);
  }

  List<Widget> _buildResult(BuildContext context, AiGrammarResult result) {
    final children = <Widget>[];

    if (!result.skeleton.isEmpty) {
      children.add(
        _SectionCard(
          icon: Icons.account_tree_outlined,
          title: 'Sentence skeleton',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.skeleton.subject != null)
                _KeyValueRow(label: 'Subject', value: result.skeleton.subject!),
              if (result.skeleton.verb != null)
                _KeyValueRow(label: 'Verb', value: result.skeleton.verb!),
              if (result.skeleton.object != null)
                _KeyValueRow(label: 'Object', value: result.skeleton.object!),
            ],
          ),
        ),
      );
    }

    if (result.clauses.isNotEmpty) {
      children.add(
        _SectionCard(
          icon: Icons.segment,
          title: 'Clauses',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < result.clauses.length; i++)
                _ClauseBlock(
                  clause: result.clauses[i],
                  last: i == result.clauses.length - 1,
                ),
            ],
          ),
        ),
      );
    }

    if (result.grammarPoints.isNotEmpty) {
      children.add(
        _SectionCard(
          icon: Icons.spellcheck,
          title: 'Grammar points',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < result.grammarPoints.length; i++)
                _GrammarPointBlock(
                  point: result.grammarPoints[i],
                  last: i == result.grammarPoints.length - 1,
                ),
            ],
          ),
        ),
      );
    }

    final tenseVoice = result.tenseVoice;
    if (tenseVoice != null && !tenseVoice.isEmpty) {
      children.add(
        _SectionCard(
          icon: Icons.schedule,
          title: 'Tense & voice',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (tenseVoice.tense != null)
                _Pill(label: 'Tense', value: tenseVoice.tense!),
              if (tenseVoice.voice != null)
                _Pill(label: 'Voice', value: tenseVoice.voice!),
              if (tenseVoice.aspect != null)
                _Pill(label: 'Aspect', value: tenseVoice.aspect!),
            ],
          ),
        ),
      );
    }

    if (result.pitfalls.isNotEmpty) {
      children.add(
        _SectionCard(
          icon: Icons.warning_amber_rounded,
          title: 'Pitfalls',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final pitfall in result.pitfalls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(
                          Icons.circle,
                          size: 6,
                          color: context.warning,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          pitfall,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return children;
  }

  Widget _buildMessage(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: context.appColorScheme.text.secondary),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.appColorScheme.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  final String message;

  const _LoadingBlock({required this.message});

  @override
  Widget build(BuildContext context) {
    // The animated spinner redraws the whole panel on e-ink; a static line is
    // the same convention as LoadingIndicator.
    if (context.eInk) {
      return Text(message, style: Theme.of(context).textTheme.bodyMedium);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(message, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _StreamPreview extends StatelessWidget {
  final String text;

  const _StreamPreview({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 16,
                color: colors.text.secondary,
              ),
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

class _TranslationCard extends StatelessWidget {
  final String translation;

  const _TranslationCard({required this.translation});

  @override
  Widget build(BuildContext context) {
    final eink = context.eInk;
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: eink
            ? colors.background.surface
            : context.m3PrimaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: eink
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
            translation,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  final AiGrammarMetaEvent meta;

  const _MetaLine({required this.meta});

  String get _providerName {
    switch (meta.provider) {
      case 'openai':
        return 'OpenAI';
      case 'anthropic':
        return 'Anthropic';
      default:
        return meta.provider ?? 'AI';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 14, color: colors.text.secondary),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              [
                _providerName,
                if (meta.model != null) meta.model!,
              ].join(' · '),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ),
          if (meta.cached)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: colors.background.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Cached',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.text.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
    final eink = context.eInk;
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        border: eink
            ? Border.all(color: colors.border.outline, width: 1.5)
            : null,
        boxShadow: eink
            ? null
            : [
                BoxShadow(
                  color: colors.text.primary.withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
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

class _KeyValueRow extends StatelessWidget {
  final String label;
  final String value;

  const _KeyValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.text.secondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClauseBlock extends StatelessWidget {
  final AiGrammarClause clause;
  final bool last;

  const _ClauseBlock({required this.clause, required this.last});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (clause.type != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.background.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    clause.type!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.text.secondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (clause.role != null)
                Expanded(
                  child: Text(
                    clause.role!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                ),
            ],
          ),
          if (clause.text != null) ...[
            const SizedBox(height: 4),
            Text(
              clause.text!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}

class _GrammarPointBlock extends StatelessWidget {
  final AiGrammarPoint point;
  final bool last;

  const _GrammarPointBlock({required this.point, required this.last});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (point.name != null)
            Text(
              point.name!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          if (point.role != null) ...[
            const SizedBox(height: 2),
            Text(
              point.role!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.text.secondary,
                height: 1.4,
              ),
            ),
          ],
          if (point.fragment != null) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
              decoration: BoxDecoration(
                border: BorderDirectional(
                  start: BorderSide(
                    color: context.eInk ? colors.text.primary : context.m3Primary,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                point.fragment!,
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

class _Pill extends StatelessWidget {
  final String label;
  final String value;

  const _Pill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.background.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.text.primary,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: colors.text.secondary),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _FallbackCard extends StatelessWidget {
  final String text;

  const _FallbackCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border.outline, width: 1),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
    );
  }
}

class _AiErrorCard extends StatelessWidget {
  final String? kind;
  final String message;
  final String? detail;
  final VoidCallback onRetry;
  final VoidCallback? onOpenWebSettings;

  const _AiErrorCard({
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
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border.outline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: context.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.text.secondary,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
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
