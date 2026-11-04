import 'package:flutter/material.dart';

import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';

/// The sentence being analysed, in the same quote-bar treatment as the
/// grammar example sentences.
class SentenceQuoteHeader extends StatelessWidget {
  final String sentence;

  const SentenceQuoteHeader({super.key, required this.sentence});

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
