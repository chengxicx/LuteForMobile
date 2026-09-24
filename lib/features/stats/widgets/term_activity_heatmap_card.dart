import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/term_activity.dart';

/// GitHub-style calendar heatmap of term activity (status changes), the same
/// panel the web stats page calls "Term activity".
class TermActivityHeatmapCard extends StatefulWidget {
  final List<TermTrendPoint> points;

  const TermActivityHeatmapCard({super.key, required this.points});

  @override
  State<TermActivityHeatmapCard> createState() =>
      _TermActivityHeatmapCardState();
}

class _TermActivityHeatmapCardState extends State<TermActivityHeatmapCard> {
  static const double _cell = 11;
  static const double _gap = 3;
  static const int _weeks = 53;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // A year of cells does not fit on a phone, and the interesting end of the
    // range is the recent one -- open on today, scroll back for history.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = <DateTime, int>{};
    for (final point in widget.points) {
      final day = DateTime(point.date.year, point.date.month, point.date.day);
      counts.update(day, (value) => value + point.count, ifAbsent: () => point.count);
    }

    final total = counts.values.fold<int>(0, (a, b) => a + b);
    final max = counts.values.isEmpty
        ? 0
        : counts.values.reduce((a, b) => a > b ? a : b);

    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    // Columns run Sunday..Saturday, like the web grid.
    final lastSaturday = todayDate.add(Duration(days: 6 - todayDate.weekday % 7));
    final firstSunday = lastSaturday.subtract(
      Duration(days: _weeks * 7 - 1),
    );

    final columns = <Widget>[];
    for (var week = 0; week < _weeks; week++) {
      final cells = <Widget>[];
      for (var day = 0; day < 7; day++) {
        final date = firstSunday.add(Duration(days: week * 7 + day));
        final isFuture = date.isAfter(todayDate);
        final count = counts[date] ?? 0;
        cells.add(
          Padding(
            padding: const EdgeInsets.only(bottom: _gap),
            child: Container(
              width: _cell,
              height: _cell,
              decoration: BoxDecoration(
                color: isFuture
                    ? Colors.transparent
                    : _cellColor(context, _levelFor(count, max)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      }
      columns.add(
        Padding(
          padding: const EdgeInsets.only(right: _gap),
          child: Column(mainAxisSize: MainAxisSize.min, children: cells),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Term Activity',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Terms you touched, by day, over the last year',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMonthLabels(context, firstSunday),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDayLabels(context),
                      ...columns,
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Total: $total',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Text(
                  'Less',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 6),
                for (var level = 0; level <= 4; level++) ...[
                  Container(
                    width: _cell,
                    height: _cell,
                    decoration: BoxDecoration(
                      color: _cellColor(context, level),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: _gap),
                ],
                Text('More', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A month is labelled on the first column that starts inside it.
  Widget _buildMonthLabels(BuildContext context, DateTime firstSunday) {
    const labelWidth = 28.0;
    final labels = <Widget>[];
    int? lastMonth;

    for (var week = 0; week < _weeks; week++) {
      final date = firstSunday.add(Duration(days: week * 7));
      final month = date.month;
      final show = month != lastMonth && date.day <= 7;
      lastMonth = month;
      labels.add(
        SizedBox(
          width: _cell + _gap,
          child: show
              ? Text(
                  _monthAbbreviation(month),
                  // The box is one week column wide (~14px) but "May" needs
                  // ~20px at this size, so the label must be allowed to run
                  // past it -- wrapping would split it into "Ma" / "y".
                  // Labels are 4+ weeks apart, so there is room to overflow.
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: context.appColorScheme.text.secondary,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: labelWidth, bottom: 4),
      child: Row(children: labels),
    );
  }

  Widget _buildDayLabels(BuildContext context) {
    const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return SizedBox(
      width: 28,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final day in days)
            SizedBox(
              height: _cell + _gap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  day,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: context.appColorScheme.text.secondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _cellColor(BuildContext context, int level) {
    final primary = context.m3Primary;
    switch (level) {
      case 0:
        return context.appColorScheme.background.surfaceContainerHighest;
      case 1:
        return primary.withValues(alpha: 0.28);
      case 2:
        return primary.withValues(alpha: 0.5);
      case 3:
        return primary.withValues(alpha: 0.74);
      default:
        return primary;
    }
  }

  int _levelFor(int count, int max) {
    if (count <= 0 || max <= 0) return 0;
    final ratio = count / max;
    if (ratio <= 0.25) return 1;
    if (ratio <= 0.5) return 2;
    if (ratio <= 0.75) return 3;
    return 4;
  }

  String _monthAbbreviation(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }
}
