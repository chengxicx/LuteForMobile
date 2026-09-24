import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../providers/stats_provider.dart';
import '../providers/term_activity_provider.dart';
import 'term_activity_heatmap_card.dart';
import 'term_summary_card.dart';
import 'term_trend_chart_card.dart';

/// The four term panels the web stats page builds from `/stats/term_data`:
/// summary, new terms, fully mastered terms and the activity heatmap.
///
/// They share one request, so they share one loading and one error state --
/// four spinners for one call would be noise.
class TermActivitySection extends ConsumerWidget {
  const TermActivitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(statsPeriodProvider);
    final langId = ref.watch(statsSelectedLangIdProvider);
    final webPeriod = webPeriodFor(period);

    final activity = ref.watch(
      termActivityProvider((period: webPeriod, langId: langId)),
    );

    return activity.when(
      loading: () => const _Placeholder(
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => _Placeholder(
        child: Row(
          children: [
            Icon(Icons.error_outline, color: context.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Could not load term statistics: $error',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(
                termActivityProvider((period: webPeriod, langId: langId)),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (data) {
        final periodLabel = webPeriod == '7days'
            ? 'last 7 days'
            : 'last 12 months';

        return Column(
          children: [
            TermSummaryCard(summary: data.summary),
            TermTrendChartCard(
              title: 'New Terms',
              subtitle: 'Terms added · $periodLabel',
              points: data.newTerms,
              color: context.m3Primary,
            ),
            TermTrendChartCard(
              title: 'Fully Mastered Terms',
              subtitle: 'Terms marked known · $periodLabel',
              points: data.masteredTerms,
              color: context.getStatusColorForVisualization('99'),
            ),
            TermActivityHeatmapCard(points: data.heatmap),
          ],
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  final Widget child;

  const _Placeholder({required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: child,
      ),
    );
  }
}
