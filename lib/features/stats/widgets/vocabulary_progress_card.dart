import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/level_report.dart';
import '../providers/level_report_provider.dart';

/// Vocabulary progress against a graded word list (JLPT / CEFR / TOPIK / ...),
/// the mobile counterpart of the web stats page's per-language progress
/// panels: an overview of mastered vs seen, then a bar per level.
///
/// A language can have more than one list (Chinese: HSK 2.0 and 3.0), so the
/// card carries its own list selector and is keyed by language id by the
/// caller -- switching language resets the choice.
class VocabularyProgressCard extends ConsumerStatefulWidget {
  final int langId;
  final List<LevelReportKind> kinds;

  const VocabularyProgressCard({
    super.key,
    required this.langId,
    required this.kinds,
  });

  @override
  ConsumerState<VocabularyProgressCard> createState() =>
      _VocabularyProgressCardState();
}

class _VocabularyProgressCardState
    extends ConsumerState<VocabularyProgressCard> {
  late LevelReportKind _kind = widget.kinds.first;

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(
      levelReportProvider((kind: _kind, langId: widget.langId)),
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vocabulary Progress',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              _kind.source,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
            if (widget.kinds.length > 1) ...[
              const SizedBox(height: 12),
              SegmentedButton<LevelReportKind>(
                segments: widget.kinds
                    .map(
                      (kind) => ButtonSegment<LevelReportKind>(
                        value: kind,
                        label: Text(kind.label),
                      ),
                    )
                    .toList(),
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _kind = selection.first);
                },
              ),
            ],
            const SizedBox(height: 16),
            report.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stack) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: context.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Could not load this report: $error',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref.invalidate(
                        levelReportProvider((
                          kind: _kind,
                          langId: widget.langId,
                        )),
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (data) => _buildReport(context, data),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReport(BuildContext context, LevelReport report) {
    if (report.isEmpty) {
      return Text(
        'No word list data for this language yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: context.appColorScheme.text.secondary,
        ),
      );
    }

    final colors = _levelColors(_kind);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildMacro(
                context,
                label: 'Mastered',
                percent: report.masteredPercent,
                detail: '${_formatNumber(report.totalMastered)} of '
                    '${_formatNumber(report.total)} terms',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMacro(
                context,
                label: 'Seen',
                percent: report.seenPercent,
                detail: '${_formatNumber(report.totalSeen)} of '
                    '${_formatNumber(report.total)} terms',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < report.levels.length; i++) ...[
          _buildLevelRow(
            context,
            level: report.levels[i],
            color: colors[i % colors.length],
            label: _kind.levelLabel(report.levels[i].level),
          ),
          if (i != report.levels.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildMacro(
    BuildContext context, {
    required String label,
    required double percent,
    required String detail,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appColorScheme.background.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.appColorScheme.text.secondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${percent.toStringAsFixed(1)}%',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: context.m3Primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.appColorScheme.text.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelRow(
    BuildContext context, {
    required LevelProgress level,
    required Color color,
    required String label,
  }) {
    return Row(
      children: [
        Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 14,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: context
                            .appColorScheme
                            .background
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    // Seen but not mastered, then mastered on top -- the same
                    // two-layer bar the web panel draws.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: width * level.seenRatio,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: width * level.masteredRatio,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 78,
          child: Text(
            '${_formatNumber(level.mastered)}/${_formatNumber(level.total)}',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.appColorScheme.text.secondary,
            ),
          ),
        ),
      ],
    );
  }

  /// Per-level ramps, mirroring the web panels (hardest level in red).
  List<Color> _levelColors(LevelReportKind kind) {
    const cefr = [
      Color(0xFF4DABF7),
      Color(0xFF38D9A9),
      Color(0xFFFFD43B),
      Color(0xFFFF922B),
      Color(0xFFFF6B6B),
      Color(0xFFE64980),
    ];
    switch (kind) {
      case LevelReportKind.jlpt:
        return const [
          Color(0xFF1DC981),
          Color(0xFF22A5F7),
          Color(0xFFF2B705),
          Color(0xFFF87454),
          Color(0xFFE8463A),
        ];
      case LevelReportKind.topik:
        return const [
          Color(0xFF38D9A9),
          Color(0xFFF2B705),
          Color(0xFFE8463A),
        ];
      case LevelReportKind.thai:
        return const [
          Color(0xFF4DABF7),
          Color(0xFF38D9A9),
          Color(0xFFFFD43B),
          Color(0xFFFF922B),
          Color(0xFFFF6B6B),
        ];
      case LevelReportKind.hsk3:
        return const [
          Color(0xFF4DABF7),
          Color(0xFF38D9A9),
          Color(0xFFFFD43B),
          Color(0xFFFF922B),
          Color(0xFFFF6B6B),
          Color(0xFFE64980),
          Color(0xFF9775FA),
        ];
      default:
        return cefr;
    }
  }

  String _formatNumber(int number) {
    if (number >= 1000000) return '${(number / 1000000).toStringAsFixed(1)}M';
    if (number >= 10000) return '${(number / 1000).toStringAsFixed(1)}K';
    return number.toString();
  }
}
