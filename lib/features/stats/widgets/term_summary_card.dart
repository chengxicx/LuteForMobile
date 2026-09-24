import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/term_activity.dart';

/// The web stats page's "Summary" panel: how many terms exist, how the
/// selected period's new terms are doing, and how the whole collection is
/// distributed across the status groups.
class TermSummaryCard extends StatelessWidget {
  final TermSummary summary;

  const TermSummaryCard({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final recent = summary.group(summary.recentByStatus);
    final cumulative = summary.group(summary.cumulativeByStatus);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Term Summary', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _formatNumber(summary.totalTerms),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'total terms',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.appColorScheme.text.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSection(
              context,
              title: '${summary.recentLabel} (${summary.recentTotal})',
              counts: recent,
            ),
            const SizedBox(height: 12),
            _buildSection(context, title: 'Cumulative', counts: cumulative),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Map<TermStatusGroup, int> counts,
  }) {
    // "Other" only ever holds statuses outside Lute's documented set, so it
    // is dropped unless something actually landed there.
    final groups = TermStatusGroup.values
        .where((g) => g != TermStatusGroup.other || (counts[g] ?? 0) > 0)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: context.appColorScheme.text.secondary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: groups.map((group) {
            return Expanded(
              child: Column(
                children: [
                  Text(
                    '${counts[group] ?? 0}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _groupColor(context, group),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    group.label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.appColorScheme.text.secondary,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// Group colours come from the theme's own status palette, so the summary
  /// agrees with the term-status chart and the bookshelf bars instead of
  /// introducing a second, unrelated set of colours.
  Color _groupColor(BuildContext context, TermStatusGroup group) {
    switch (group) {
      case TermStatusGroup.unknown:
        return context.getStatusColorForVisualization('0');
      case TermStatusGroup.vague:
        return context.getStatusColorForVisualization('2');
      case TermStatusGroup.mastered:
        return context.getStatusColorForVisualization('99');
      case TermStatusGroup.ignored:
        return context.getStatusColorForVisualization('98');
      case TermStatusGroup.other:
        return context.appColorScheme.text.secondary;
    }
  }

  String _formatNumber(int number) {
    if (number >= 1000000) return '${(number / 1000000).toStringAsFixed(1)}M';
    if (number >= 1000) return '${(number / 1000).toStringAsFixed(1)}K';
    return number.toString();
  }
}
