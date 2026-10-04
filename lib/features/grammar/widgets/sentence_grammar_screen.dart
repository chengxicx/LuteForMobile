import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../models/grammar_point.dart';
import '../providers/sentence_grammar_provider.dart';
import 'grammar_point_card.dart';

/// Grammar analysis of one sentence, opened from the word card's Grammar
/// button.
///
/// The reader pre-analyses the page a few seconds after it loads (same cache
/// as the Grammar tab), so an ordinary open here is instant: the sentence is
/// looked up in that cache, and only falls back to a one-sentence request
/// when the pre-analysis cannot answer (page just turned, analysis failed,
/// or the server's sentence splitting does not line up).
class SentenceGrammarScreen extends ConsumerStatefulWidget {
  final String sentenceText;
  final int bookId;
  final int pageNum;

  const SentenceGrammarScreen({
    super.key,
    required this.sentenceText,
    required this.bookId,
    required this.pageNum,
  });

  @override
  ConsumerState<SentenceGrammarScreen> createState() =>
      _SentenceGrammarScreenState();
}

class _SentenceGrammarScreenState extends ConsumerState<SentenceGrammarScreen> {
  bool _loading = true;
  String? _errorMessage;
  List<GrammarPoint> _points = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final points = await ref
          .read(sentenceGrammarProvider.notifier)
          .getSentenceGrammar(widget.sentenceText, force: force);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _points = points;
      });
    } catch (e, stackTrace) {
      ApiLogger.logError('sentenceGrammar.load', e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sentence grammar')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const LoadingIndicator(message: 'Analyzing grammar...');
    }

    if (_errorMessage != null) {
      return ErrorDisplay(
        message: _errorMessage!,
        onRetry: () => _load(force: true),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _load(force: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SentenceHeader(sentence: widget.sentenceText),
          const SizedBox(height: 12),
          if (_points.isEmpty)
            _buildEmpty(context)
          else
            for (var i = 0; i < _points.length; i++)
              // 单句页通常只有一两个点，空间足够：参考例句·注意点默认展开，
              // 用户点了词条才打开的那一句，例句不该再藏着（2026-10-03 反馈）。
              GrammarPointCard(
                point: _points[i],
                index: i,
                initiallyExpanded: true,
              ),
        ],
      ),
    );
  }

  /// The empty state sits under the sentence header, so the sentence the
  /// user asked about stays on screen while the page explains itself.
  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: context.eInk ? null : context.m3PrimaryContainer,
              border: context.eInk
                  ? Border.all(
                      color: context.appColorScheme.border.outline,
                      width: 1.5,
                    )
                  : null,
            ),
            child: Icon(
              Icons.spellcheck,
              size: 36,
              color: context.eInk
                  ? context.appColorScheme.text.primary
                  : context.m3Primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'No grammar points matched',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Nothing in the grammar library matched this sentence.',
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

class _SentenceHeader extends StatelessWidget {
  final String sentence;

  const _SentenceHeader({required this.sentence});

  @override
  Widget build(BuildContext context) {
    // Label follows the same CJK rule as the card's fold label.
    final cjk =
        RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]').hasMatch(sentence);
    final colors = context.appColorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.format_quote, size: 14, color: colors.text.secondary),
            const SizedBox(width: 4),
            Text(
              cjk ? '原文' : 'Sentence',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.text.secondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Same quote-bar treatment as the example sentences in the cards
        // below, so the page reads as one visual family.
        Container(
          width: double.infinity,
          padding: const EdgeInsetsDirectional.only(
            start: 10,
            end: 4,
            top: 2,
            bottom: 2,
          ),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(
                color: context.eInk ? colors.text.primary : context.m3Primary,
                width: 2,
              ),
            ),
          ),
          child: Text(
            sentence,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ),
      ],
    );
  }
}
