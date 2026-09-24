import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/stats_provider.dart';
import 'summary_cards.dart';
import 'period_filter_widget.dart';
import 'language_filter_widget.dart';
import 'words_read_chart.dart';
import 'term_status_chart.dart';
import 'language_breakdown_card.dart';
import 'reading_milestones_card.dart';
import 'terms_added_today_card.dart';
import 'term_activity_section.dart';
import 'vocabulary_progress_card.dart';
import '../providers/level_report_provider.dart';
import '../providers/term_activity_provider.dart';

class StatsScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const StatsScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  int _buildCount = 0;

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('StatsScreen', _buildCount);

    final state = ref.watch(statsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
        title: const Text('Stats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(statsProvider.notifier).refreshStats(),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: state.when(
        loading: () =>
            const Center(child: LoadingIndicator(message: 'Loading stats...')),
        error: (err, stack) => ErrorDisplay(
          message: err.toString(),
          onRetry: () => ref.read(statsProvider.notifier).loadStats(),
        ),
        data: (statsState) => _buildStatsContent(context, statsState),
      ),
    );
  }

  Widget _buildStatsContent(BuildContext context, StatsState state) {
    if (state.languages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bar_chart,
              size: 64,
              color: context.appColorScheme.text.secondary,
            ),
            const SizedBox(height: 16),
            Text(
              'No stats available',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Start reading to see your statistics',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
          ],
        ),
      );
    }

    final filteredLanguages = ref
        .read(statsProvider.notifier)
        .filteredLanguages;

    // Vocabulary-progress reports are per language, so they only appear once
    // a language (not "all") is selected -- the same rule the web page uses
    // when it reveals its JLPT / CEFR / ... buttons.
    final selectedLangName = ref
        .watch(statsProvider)
        .value
        ?.selectedLanguage
        ?.language;
    final selectedLangId = ref.watch(statsSelectedLangIdProvider);
    final reportKinds = selectedLangName == null
        ? const <LevelReportKind>[]
        : levelReportKindsFor(selectedLangName);

    return RefreshIndicator(
      onRefresh: () => ref.read(statsProvider.notifier).refreshStats(),
      child: ListView(
        padding: const EdgeInsets.only(top: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SummaryCards(languages: filteredLanguages),
          ),
          const SizedBox(height: 8),
          const PeriodFilterWidget(),
          const SizedBox(height: 8),
          const LanguageFilterWidget(),
          if (selectedLangId != null && reportKinds.isNotEmpty) ...[
            const SizedBox(height: 8),
            VocabularyProgressCard(
              key: ValueKey(selectedLangId),
              langId: selectedLangId,
              kinds: reportKinds,
            ),
          ],
          const SizedBox(height: 8),
          WordsReadChart(languages: filteredLanguages),
          const TermActivitySection(),
          const TermsAddedTodayCard(),
          ReadingMilestonesCard(languages: filteredLanguages),
          const TermStatusChart(),
          LanguageBreakdownCard(languages: filteredLanguages),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
