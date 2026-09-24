import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lute_for_mobile/features/settings/providers/settings_provider.dart';
import 'package:lute_for_mobile/shared/theme/theme_extensions.dart';

/// The font families the reader can render with.  Every one of them is
/// declared in pubspec.yaml; a family that is *not* declared fails silently
/// (Flutter falls back to the default face), so this list and the pubspec
/// font block have to stay in step.
const List<String> kReaderFonts = <String>[
  'Roboto',
  'AtkinsonHyperlegibleNext',
  'Vollkorn',
  'LinBiolinum',
  'Literata',
];

/// The weights each family actually ships.
///
/// Asking for a weight a family does not have makes Flutter synthesise it,
/// which looks worse than the nearest real one -- so the slider is limited to
/// the declared faces instead of offering all nine weights for every family.
const Map<String, List<FontWeight>> _kFontWeights = <String, List<FontWeight>>{
  'Roboto': <FontWeight>[
    FontWeight.w200,
    FontWeight.w300,
    FontWeight.normal,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.bold,
    FontWeight.w800,
  ],
  'AtkinsonHyperlegibleNext': <FontWeight>[
    FontWeight.w200,
    FontWeight.w300,
    FontWeight.normal,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.bold,
    FontWeight.w800,
  ],
  'Vollkorn': <FontWeight>[
    FontWeight.normal,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.bold,
    FontWeight.w900,
  ],
  'LinBiolinum': <FontWeight>[FontWeight.normal, FontWeight.bold],
  'Literata': <FontWeight>[
    FontWeight.normal,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.bold,
  ],
};

const Map<int, String> _kWeightLabels = <int, String>{
  200: 'Extra Light',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'Semi Bold',
  700: 'Bold',
  800: 'Extra Bold',
  900: 'Black',
};

/// Weights available for [fontFamily], falling back to the Roboto set.
List<FontWeight> availableWeightsFor(String fontFamily) {
  return _kFontWeights[fontFamily] ?? _kFontWeights['Roboto']!;
}

String weightLabel(FontWeight weight) {
  return _kWeightLabels[weight.value] ?? 'Regular';
}

/// One run of preview text: the characters, plus the term status whose colours
/// it should wear (null = plain body text, not a term).
typedef PreviewToken = ({String text, String? status});

/// Text size / line spacing / font / weight / italic, with a live preview.
///
/// One widget, used by both the reader drawer panel and Settings > Reading.
/// They used to hold separate copies of these controls, and the drawer's copy
/// lived at the bottom of a non-scrollable Column -- so once the panel grew
/// (and the bottom navigation bar took another slice of the height) the font
/// and size controls were pushed out of reach and could not be changed at all.
///
/// The preview is not decoration: without it these controls edit text that is
/// either on another screen (Settings) or hidden behind this panel (the reader
/// drawer), so a size change had no visible effect at all.  Its height is
/// fixed so that growing the text cannot push the sliders out from under the
/// finger doing the dragging.
class TextFormattingControls extends ConsumerWidget {
  /// Tighter vertical rhythm for the drawer, where space is scarce.
  final bool dense;

  /// Real text to preview -- the caller passes the page being read so the
  /// preview is in the reader's own language and script.  A font size is not
  /// comparable across scripts, so sizing Chinese or Arabic against a Latin
  /// sample would set it wrong without the reader noticing.  Null falls back
  /// to [_kSample].
  final List<PreviewToken>? previewTokens;

  const TextFormattingControls({
    super.key,
    this.dense = false,
    this.previewTokens,
  });

  static const double _minTextSize = 12;
  static const double _maxTextSize = 30;

  /// Used when no page is open (Settings, or a book that has not loaded).
  static const List<PreviewToken> _kSample = <PreviewToken>[
    (text: 'Reading ', status: null),
    (text: 'a ', status: null),
    (text: 'book ', status: null),
    (text: 'in ', status: null),
    (text: 'another ', status: null),
    (text: 'language ', status: '1'),
    (text: 'is ', status: null),
    (text: 'a ', status: null),
    (text: 'quiet ', status: null),
    (text: 'kind ', status: null),
    (text: 'of ', status: null),
    (text: 'happiness.', status: '99'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(textFormattingSettingsProvider);
    final weights = availableWeightsFor(settings.fontFamily);

    var weightIndex = weights.indexOf(settings.fontWeight);
    if (weightIndex == -1) {
      weightIndex = weights.indexOf(FontWeight.normal);
      if (weightIndex == -1) weightIndex = 0;
    }

    final gap = SizedBox(height: dense ? 12 : 20);
    final notifier = ref.read(textFormattingSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreview(context, settings),
        gap,
        _buildSlider(
          context,
          label: 'Text Size',
          value: '${settings.textSize.toInt()}',
          // Rounded: a restored preference can be fractional, and stepping off
          // one should land on a whole point either way.
          stepDown: settings.textSize > _minTextSize
              ? () => notifier.updateTextSize(
                  (settings.textSize - 1).roundToDouble(),
                )
              : null,
          stepUp: settings.textSize < _maxTextSize
              ? () => notifier.updateTextSize(
                  (settings.textSize + 1).roundToDouble(),
                )
              : null,
          slider: Slider(
            value: _within(settings.textSize, _minTextSize, _maxTextSize),
            min: _minTextSize,
            max: _maxTextSize,
            divisions: (_maxTextSize - _minTextSize).toInt(),
            label: '${settings.textSize.toInt()}',
            onChanged: (value) => notifier.updateTextSize(value),
            // Size writes are debounced; ending the gesture commits the last
            // one at once, so backing out cannot drop it.
            onChangeEnd: (_) => notifier.flushPendingWrites(),
          ),
        ),
        gap,
        _buildSlider(
          context,
          label: 'Line Spacing',
          value: settings.lineSpacing.toStringAsFixed(1),
          slider: Slider(
            value: _within(settings.lineSpacing, 0.6, 2.0),
            min: 0.6,
            max: 2.0,
            divisions: 14,
            label: settings.lineSpacing.toStringAsFixed(1),
            onChanged: (value) => notifier.updateLineSpacing(value),
            onChangeEnd: (_) => notifier.flushPendingWrites(),
          ),
        ),
        gap,
        _buildLabel(context, 'Font'),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          // Keyed by the family so the field rebuilds when the family changes
          // elsewhere -- the reader drawer edits the same setting.
          key: ValueKey(settings.fontFamily),
          initialValue: settings.fontFamily,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: kReaderFonts.map((String font) {
            return DropdownMenuItem<String>(
              value: font,
              child: Text(font, style: TextStyle(fontFamily: font)),
            );
          }).toList(),
          onChanged: (String? newValue) {
            if (newValue == null) return;
            // A family that does not ship the current weight has to move to
            // one it does, otherwise the weight slider would sit on an index
            // the new family cannot express.
            final nextWeights = availableWeightsFor(newValue);
            notifier.updateFontFamily(newValue);
            if (!nextWeights.contains(settings.fontWeight)) {
              notifier.updateFontWeight(
                nextWeights.contains(FontWeight.normal)
                    ? FontWeight.normal
                    : nextWeights.first,
              );
            }
          },
        ),
        gap,
        _buildLabel(context, 'Weight'),
        const SizedBox(height: 8),
        // Chips rather than a slider: weight is a small set of named values
        // for the family in use, and dragging an index gave no way to see
        // what "4" meant.  Only the weights this family ships are listed, so
        // there is nothing to disable.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (var i = 0; i < weights.length; i++)
              ChoiceChip(
                label: Text(weightLabel(weights[i])),
                selected: i == weightIndex,
                onSelected: (_) => notifier.updateFontWeight(weights[i]),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: i == weightIndex
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : Theme.of(context).textTheme.bodyMedium?.color,
                ),
              ),
          ],
        ),
        gap,
        Row(
          children: [
            Expanded(child: _buildLabel(context, 'Italic')),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                value: settings.isItalic,
                onChanged: (value) => notifier.updateIsItalic(value),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Sample text rendered with the settings being edited.
  ///
  /// Fixed height and clipped: if the box grew with its content, dragging the
  /// size slider would move the slider itself down the screen.
  Widget _buildPreview(BuildContext context, TextFormattingSettings settings) {
    final tokens = previewTokens ?? _kSample;
    final defaultColor = Theme.of(context).textTheme.bodyLarge?.color;

    return Container(
      height: dense ? 92 : 116,
      width: double.infinity,
      clipBehavior: Clip.hardEdge,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appColorScheme.background.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.appColorScheme.border.dividerColor),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              for (final token in tokens)
                TextSpan(
                  text: token.text,
                  style: TextStyle(
                    fontFamily: settings.fontFamily,
                    fontSize: settings.textSize,
                    height: settings.lineSpacing,
                    fontWeight: settings.fontWeight,
                    fontStyle: settings.isItalic
                        ? FontStyle.italic
                        : FontStyle.normal,
                    color: token.status == null
                        ? defaultColor
                        : context.getStatusTextColor(token.status!),
                    backgroundColor: token.status == null
                        ? null
                        : context.getStatusBackgroundColor(token.status!),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slider values have to sit inside their own range, or Slider asserts.
  /// A stored preference could be outside it (an older build, a restore).
  double _within(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  Widget _buildLabel(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
    );
  }

  Widget _buildSlider(
    BuildContext context, {
    required String label,
    required String value,
    required Widget slider,
    VoidCallback? stepDown,
    VoidCallback? stepUp,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _buildLabel(context, label)),
            Text(
              value,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Row(
          children: [
            if (stepDown != null) _buildStepButton(context, 'A−', stepDown),
            Expanded(child: SizedBox(height: dense ? 32 : 40, child: slider)),
            if (stepUp != null) _buildStepButton(context, 'A+', stepUp),
          ],
        ),
      ],
    );
  }

  /// A stepper beside the slider: in a 240px panel the thumb is awkward to
  /// land on an exact value, and one tap per point is quicker.
  Widget _buildStepButton(
    BuildContext context,
    String label,
    VoidCallback onPressed,
  ) {
    return SizedBox(
      width: 34,
      height: 32,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(34, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Text(label),
      ),
    );
  }
}
