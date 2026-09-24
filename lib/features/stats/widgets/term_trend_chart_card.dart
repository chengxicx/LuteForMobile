import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/term_activity.dart';

/// One term-trend chart: how many terms were created, or fully mastered, in
/// each bucket of the selected period.
///
/// Used twice on the stats screen ("New terms" and "Fully mastered terms"),
/// mirroring the two charts on the web stats page.
class TermTrendChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<TermTrendPoint> points;
  final Color color;

  const TermTrendChartCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.points,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final maxCount = points.isEmpty
        ? 0
        : points.map((p) => p.count).reduce((a, b) => a > b ? a : b);

    // Monthly buckets carry the first of the month, so a day label would be
    // noise there -- show the month instead once the buckets are far apart.
    final monthly =
        points.length >= 2 &&
        points.last.date.difference(points.first.date).inDays /
                (points.length - 1) >=
            25;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.appColorScheme.text.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (points.isNotEmpty)
                  Text(
                    '${points.fold<int>(0, (a, b) => a + b.count)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (points.isEmpty)
              SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    'Nothing in this period.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.appColorScheme.text.secondary,
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                height: 180,
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: (points.length - 1).toDouble(),
                    minY: 0,
                    maxY: maxCount == 0 ? 10 : maxCount * 1.15,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: _yInterval(maxCount),
                    ),
                    borderData: FlBorderData(
                      show: true,
                      border: Border(
                        bottom: BorderSide(
                          color: context.appColorScheme.border.outline,
                        ),
                        left: BorderSide(
                          color: context.appColorScheme.border.outline,
                        ),
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          interval: _yInterval(maxCount),
                          getTitlesWidget: (value, meta) => Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          interval: _xInterval(points.length),
                          getTitlesWidget: (value, meta) {
                            final index = value.round();
                            if (index < 0 || index >= points.length) {
                              return const SizedBox.shrink();
                            }
                            final date = points[index].date;
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                monthly
                                    ? '${date.month}/${date.year % 100}'
                                    : '${date.month}/${date.day}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipColor: (spot) => context
                            .appColorScheme
                            .background
                            .surfaceContainerHighest,
                        getTooltipItems: (spots) => spots.map((spot) {
                          final index = spot.x.round().clamp(
                            0,
                            points.length - 1,
                          );
                          return LineTooltipItem(
                            '${_formatFullDate(points[index].date)}\n'
                            '${points[index].count} terms',
                            TextStyle(
                              color: context.appColorScheme.text.primary,
                              fontSize: 12,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < points.length; i++)
                            FlSpot(i.toDouble(), points[i].count.toDouble()),
                        ],
                        isCurved: false,
                        color: color,
                        barWidth: 2.5,
                        dotData: FlDotData(show: points.length <= 20),
                        belowBarData: BarAreaData(
                          show: true,
                          color: color.withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  double _yInterval(int maxCount) {
    if (maxCount <= 5) return 1;
    if (maxCount <= 20) return 5;
    if (maxCount <= 100) return 20;
    if (maxCount <= 500) return 100;
    return (maxCount / 5).ceilToDouble();
  }

  /// Aim for four or five labels, whatever the bucket count.
  double _xInterval(int length) {
    if (length <= 1) return 1;
    return (length / 4).ceilToDouble();
  }

  String _formatFullDate(DateTime date) => '${date.year}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
