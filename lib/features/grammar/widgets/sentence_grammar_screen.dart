import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../reader/providers/current_book_provider.dart';
import '../models/grammar_point.dart';
import '../providers/sentence_grammar_provider.dart';
import 'ai_grammar_panel.dart';
import 'grammar_point_card.dart';
import 'sentence_quote_header.dart';

/// Grammar analysis of one sentence, opened from the word card's Grammar
/// button.
///
/// Two tabs keep the two engines visibly separate: the local grammar library
/// (the same `/read/grammar_analysis` cache the reader pre-analyses) and the
/// server-side AI provider (`/ai/grammar/analyze`).
class SentenceGrammarScreen extends ConsumerStatefulWidget {
  final String sentenceText;
  final int bookId;
  final int pageNum;

  /// Language of the sentence, used by the AI tab.  Falls back to the
  /// current book when the caller cannot supply it.
  final int? langId;

  /// 0 = local grammar library, 1 = AI analysis.
  final int initialTab;

  const SentenceGrammarScreen({
    super.key,
    required this.sentenceText,
    required this.bookId,
    required this.pageNum,
    this.langId,
    this.initialTab = 0,
  });

  @override
  ConsumerState<SentenceGrammarScreen> createState() =>
      _SentenceGrammarScreenState();
}

class _SentenceGrammarScreenState extends ConsumerState<SentenceGrammarScreen>
    with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _errorMessage;
  List<GrammarPoint> _points = const [];

  late final TabController _tabController;
  bool _aiActive = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _aiActive = widget.initialTab == 1;
    _tabController.addListener(_handleTabChanged);
    _load();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    final active = _tabController.index == 1;
    if (active != _aiActive) {
      setState(() => _aiActive = active);
    }
  }

  int? get _langId =>
      widget.langId ?? ref.read(currentBookProvider).langId;

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
      appBar: AppBar(
        title: const Text('Sentence grammar'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Grammar library'),
            Tab(text: 'AI analysis'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLocalBody(context),
          AiGrammarPanel(
            sentence: widget.sentenceText,
            langId: _langId,
            active: _aiActive,
          ),
        ],
      ),
    );
  }

  Widget _buildLocalBody(BuildContext context) {
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
          SentenceQuoteHeader(sentence: widget.sentenceText),
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
