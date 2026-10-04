import 'package:flutter/material.dart';

import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/grammar_point.dart';

/// One grammar point: index chip, name, level badge, explanation, examples.
///
/// Rendered identically on the page-level Grammar screen and on the
/// sentence grammar screen the word card opens.
class GrammarPointCard extends StatelessWidget {
  final GrammarPoint point;

  /// Position in the list, rendered as the 01/02... chip in the header row.
  final int? index;

  /// Whether the 参考例句·注意点 fold starts open.  The Grammar tab lists many
  /// points and stays collapsed; the single-sentence screen has room, so it
  /// passes true (2026-10-03 反馈：单句页空间足够，例句不用缩）.
  final bool initiallyExpanded;

  const GrammarPointCard({
    super.key,
    required this.point,
    this.index,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final desc = point.desc;
    // Same label rule as the web panel: a CJK explanation means the entry
    // speaks Chinese, so the summary line does too.
    final cjkDesc =
        RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]').hasMatch(desc ?? '');
    final moreLabel = cjkDesc ? '参考例句 · 注意点' : 'Reference · notes';

    final eink = context.eInk;
    final colors = context.appColorScheme;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 14, 16, 14),
      decoration: BoxDecoration(
        color: colors.background.surface,
        borderRadius: BorderRadius.circular(12),
        // 彩色主题：左侧强调条 + 轻阴影。墨水屏：阴影在 16 灰阶里是脏灰，
        // 按 term_tooltip 卡片的语言换成四周实线描边，强调条变成墨色竖线。
        border: eink
            ? BorderDirectional(
                start: BorderSide(color: colors.text.primary, width: 4),
                top: BorderSide(color: colors.border.outline, width: 1.5),
                end: BorderSide(color: colors.border.outline, width: 1.5),
                bottom: BorderSide(color: colors.border.outline, width: 1.5),
              )
            : BorderDirectional(
                start: BorderSide(color: context.m3Primary, width: 3),
              ),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (index != null) ...[
                _IndexChip(index: index!),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  point.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (point.level != null) ...[
                const SizedBox(width: 8),
                _LevelBadge(level: point.level!),
              ],
            ],
          ),
          if (point.formation != null) ...[
            const SizedBox(height: 10),
            _FormationBlock(formation: point.formation!),
          ],
          if (desc != null) ...[
            const SizedBox(height: 8),
            Text(
              desc,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
          ],
          if (point.examples.isNotEmpty) const SizedBox(height: 12),
          ...point.examples.map(
            (example) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ExampleSentence(example: example),
            ),
          ),
          if (point.reference != null || point.notes != null) ...[
            const SizedBox(height: 4),
            _ReferenceNotesSection(
              label: moreLabel,
              reference: point.reference,
              notes: point.notes,
              initiallyExpanded: initiallyExpanded,
            ),
          ],
        ],
      ),
    );
  }
}

/// Header row's position chip: 01, 02, ...
class _IndexChip extends StatelessWidget {
  final int index;

  const _IndexChip({required this.index});

  @override
  Widget build(BuildContext context) {
    final eink = context.eInk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: eink
            ? context.appColorScheme.background.surfaceContainerHighest
            : context.m3PrimaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${index + 1}'.padLeft(2, '0'),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: eink
              ? context.appColorScheme.text.primary
              : context.appColorScheme.text.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The folded "reference example + notes" block, mirroring the web panel's
/// `<details class="grammar-item__more">`: collapsed by default, tap to open
/// (the sentence grammar screen flips the default via initiallyExpanded).
/// No animation -- the reader runs on e-ink devices.
class _ReferenceNotesSection extends StatefulWidget {
  final String label;
  final GrammarReference? reference;
  final String? notes;

  /// Whether the fold starts open (see GrammarPointCard.initiallyExpanded).
  final bool initiallyExpanded;

  const _ReferenceNotesSection({
    required this.label,
    this.reference,
    this.notes,
    this.initiallyExpanded = false,
  });

  @override
  State<_ReferenceNotesSection> createState() => _ReferenceNotesSectionState();
}

class _ReferenceNotesSectionState extends State<_ReferenceNotesSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final reference = widget.reference;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(
          height: 17,
          thickness: 1,
          color: context.appColorScheme.border.dividerColor,
        ),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: context.appColorScheme.text.secondary,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.appColorScheme.text.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          if (reference != null && reference.sentence.isNotEmpty) ...[
            _ExampleSentence(
              example: GrammarExample(
                sentence: reference.sentence,
                matches: reference.matches,
              ),
            ),
            if (reference.text != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12),
                child: Text(
                  reference.text!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.appColorScheme.text.secondary,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
          if (widget.notes != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
              child: Text(
                widget.notes!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// JLPT/CEFR level badge.  Levels ride a green→red difficulty ramp (same
/// family as NewWordDifficultyBadge); e-ink swaps colour for a lightness
/// ramp with contrast-flipped text.  Unrecognised levels fall back to the
/// neutral secondary-container pill rather than pretending to be a level.
class _LevelBadge extends StatelessWidget {
  final String level;

  const _LevelBadge({required this.level});

  static const _ramp = <(Color, Color)>[
    (Color(0xFF72DA88), Color(0xFF1A5F2A)), // N5 / A1
    (Color(0xFFFFD43B), Color(0xFF7A6000)), // N4 / A2
    (Color(0xFFFFA94D), Color(0xFF8A4500)), // N3 / B1
    (Color(0xFFFF8787), Color(0xFF9B1C1C)), // N2 / B2
    (Color(0xFFFF6B6B), Color(0xFF8B1A1A)), // N1 / C1-C2
  ];

  static const _einkLight = <(Color, Color)>[
    (Color(0xFFE8E8E8), Color(0xFF000000)),
    (Color(0xFFCCCCCC), Color(0xFF000000)),
    (Color(0xFFB4B4B4), Color(0xFF000000)),
    (Color(0xFF6E6E6E), Color(0xFFFFFFFF)),
    (Color(0xFF3A3A3A), Color(0xFFFFFFFF)),
  ];

  static const _einkDark = <(Color, Color)>[
    (Color(0xFF2E2E2E), Color(0xFFFFFFFF)),
    (Color(0xFF474747), Color(0xFFFFFFFF)),
    (Color(0xFF6E6E6E), Color(0xFFFFFFFF)),
    (Color(0xFFB4B4B4), Color(0xFF000000)),
    (Color(0xFFE8E8E8), Color(0xFF000000)),
  ];

  static int? _rampStep(String level) {
    switch (level.toUpperCase()) {
      case 'N5':
      case 'A1':
        return 0;
      case 'N4':
      case 'A2':
        return 1;
      case 'N3':
      case 'B1':
        return 2;
      case 'N2':
      case 'B2':
        return 3;
      case 'N1':
      case 'C1':
      case 'C2':
        return 4;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _rampStep(level);
    if (step == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: context.m3SecondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          level,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: context.appColorScheme.text.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    final (bg, fg) = context.eInk
        ? (Theme.of(context).brightness == Brightness.dark
              ? _einkDark[step]
              : _einkLight[step])
        : _ramp[step];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        level.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The curated formation line ("動ます形 + たり〜たり"), pulled out of the
/// prose into its own tinted block so the pattern reads at a glance.
class _FormationBlock extends StatelessWidget {
  final String formation;

  const _FormationBlock({required this.formation});

  @override
  Widget build(BuildContext context) {
    final eink = context.eInk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: eink
            ? context.appColorScheme.background.surfaceContainerHighest
            : context.m3PrimaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        formation,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: eink
              ? context.appColorScheme.text.primary
              : context.appColorScheme.text.onPrimaryContainer,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}

/// An example sentence with the matched fragments marked.  Quote-bar style:
/// a 2px rule on the start edge instead of a filled block, so the formation
/// block above and the match highlight inside stay the only colour fills.
class _ExampleSentence extends StatelessWidget {
  final GrammarExample example;

  const _ExampleSentence({required this.example});

  @override
  Widget build(BuildContext context) {
    final highlightStyle = TextStyle(
      backgroundColor: context.m3PrimaryContainer,
      color: context.appColorScheme.text.onPrimaryContainer,
      fontWeight: FontWeight.bold,
    );

    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      height: 1.4,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(
            color: context.eInk
                ? context.appColorScheme.text.primary
                : context.m3Primary,
            width: 2,
          ),
        ),
      ),
      child: RichText(
        text: TextSpan(
          style: baseStyle,
          children: _spans(highlightStyle),
        ),
      ),
    );
  }

  List<TextSpan> _spans(TextStyle highlightStyle) {
    if (example.matches.isEmpty) {
      return [TextSpan(text: example.sentence)];
    }

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in example.matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: example.sentence.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: example.sentence.substring(match.start, match.end),
          style: highlightStyle,
        ),
      );
      cursor = match.end;
    }
    if (cursor < example.sentence.length) {
      spans.add(TextSpan(text: example.sentence.substring(cursor)));
    }
    return spans;
  }
}
