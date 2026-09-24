import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/shared/utils/number_input.dart';

void main() {
  const min = 1;
  const max = 10;

  NumberInput resolve(String raw, {String fallback = '5'}) {
    return resolveNumberInput(raw, min: min, max: max, fallback: fallback);
  }

  group('resolveNumberInput', () {
    test('an in-range value passes through unchanged', () {
      final r = resolve('7');
      expect(r.value, '7', reason: '7 is inside 1-10 and needs no adjustment');
      expect(r.error, isNull);
    });

    test('the bounds themselves are in range', () {
      expect(resolve('1').value, '1', reason: 'min is inclusive');
      expect(resolve('10').value, '10', reason: 'max is inclusive');
      expect(resolve('1').error, isNull);
      expect(resolve('10').error, isNull);
    });

    // The bug this replaced: per-keystroke saving kept the 5 (the only
    // in-range prefix of 500) and dropped the rest, so the setting was 5
    // while the field read 500.
    test('an over-long entry clamps to max, not to its in-range prefix', () {
      final r = resolve('500');
      expect(r.value, '10', reason: '500 must clamp to 10, not keep the 5');
      expect(r.error, 'Maximum is 10');
    });

    test('below min clamps to min', () {
      final r = resolve('0');
      expect(r.value, '1', reason: '0 is below the 1-10 range');
      expect(r.error, 'Minimum is 1');
    });

    test('empty input falls back to the value in effect', () {
      final r = resolve('');
      expect(r.value, '5', reason: 'nothing was entered, so nothing changes');
      expect(r.error, isNull, reason: 'an empty field is not an error state');
    });

    test('unparseable input falls back to the value in effect', () {
      expect(resolve('abc').value, '5');
      expect(resolve('abc').error, isNull);
    });

    test('surrounding whitespace is ignored', () {
      expect(resolve('  7  ').value, '7');
      expect(resolve('  70  ').value, '10');
    });

    test('leading zeros are normalised', () {
      expect(resolve('007').value, '7');
    });

    test('the reported bounds follow the field, not a fixed range', () {
      final wide = resolveNumberInput(
        '9999',
        min: 1,
        max: 500,
        fallback: '100',
      );
      expect(wide.value, '500');
      expect(wide.error, 'Maximum is 500');
    });
  });
}
