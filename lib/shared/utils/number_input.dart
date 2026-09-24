/// What a raw number-field entry resolves to: the value that takes effect,
/// plus the reason it is not what was typed (null when it is).
typedef NumberInput = ({String value, String? error});

/// Resolves a bounded integer field's raw text.
///
/// Out-of-range input is *clamped*, not discarded -- and the reason is handed
/// back so the field can say so.  The widget used to reject out-of-range
/// keystrokes silently, which lost values: typing 500 into a 1-10 field saved
/// the 5 (the only in-range prefix), dropped the rest, and left the field
/// showing 500 while the setting was 5.
///
/// Kept out of the widget so this rule is testable without a widget harness.
NumberInput resolveNumberInput(
  String raw, {
  required int min,
  required int max,
  required String fallback,
}) {
  final parsed = int.tryParse(raw.trim());

  // Empty or unparseable: fall back to what is in effect rather than to a
  // guess -- there is nothing to clamp.
  if (parsed == null) {
    return (value: fallback, error: null);
  }
  if (parsed < min) {
    return (value: min.toString(), error: 'Minimum is $min');
  }
  if (parsed > max) {
    return (value: max.toString(), error: 'Maximum is $max');
  }
  return (value: parsed.toString(), error: null);
}
