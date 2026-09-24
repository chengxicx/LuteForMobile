// 配色约束守护测试。
//
// 校验五件事：
//   1. 同主题内任意两档状态色的 CIE76 ΔE >= 25（人眼可区分）
//   2. 状态色与其上文字（highlightedText）的对比度 >= 4.5（WCAG AA 正文）
//   3. 状态色与页面底色的对比度 >= 3.0（WCAG AA 非文本）
//   4. 同主题内不存在两个完全相同的状态色
//   5. 播放行底色（playingLineHighlight，见 theme_extensions.dart）与页面底色
//      可区分（ΔE >= 20），且其上的文字对比度 >= 4.5 —— 它是"播到哪一行"的唯一
//      提示，糊在底色里或看不清字都等于没做
//
// 运行：flutter test test/palette_contrast_test.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/shared/theme/theme_definitions.dart';
import 'package:lute_for_mobile/shared/theme/theme_presets.dart';

// ---------------------------------------------------------------------------
// 色彩科学
// ---------------------------------------------------------------------------

double _srgbToLinear(double v) =>
    v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

/// WCAG 相对亮度
double relativeLuminance(Color c) =>
    0.2126 * _srgbToLinear(c.r) +
    0.7152 * _srgbToLinear(c.g) +
    0.0722 * _srgbToLinear(c.b);

/// WCAG 对比度
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// sRGB -> CIELAB（D65 白点）
List<double> toLab(Color c) {
  final r = _srgbToLinear(c.r);
  final g = _srgbToLinear(c.g);
  final b = _srgbToLinear(c.b);

  final x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
  final y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
  final z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883;

  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;

  final fx = f(x);
  final fy = f(y);
  final fz = f(z);
  return <double>[116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

/// CIE76 色差
double deltaE76(Color a, Color b) {
  final la = toLab(a);
  final lb = toLab(b);
  final dl = la[0] - lb[0];
  final da = la[1] - lb[1];
  final db = la[2] - lb[2];
  return math.sqrt(dl * dl + da * da + db * db);
}

// ---------------------------------------------------------------------------
// 调色板抽象
// ---------------------------------------------------------------------------

class _Palette {
  _Palette({
    required this.name,
    required this.swatches,
    required this.background,
    required this.onSwatch,
    required this.playingMark,
    required this.pageText,
    required this.minDeltaE,
  });

  final String name;
  final Map<String, Color> swatches;
  final Color background;
  final Color onSwatch;

  /// 播放行底色的"颜料"（audio.bookmark）与页面正文字色（text.primary）。
  /// 前者由 theme_extensions.playingLineHighlight 以 28% 压到页面底色上，
  /// 后者是那一行上实际绘制的字色。
  final Color playingMark;
  final Color pageText;

  /// 该主题可接受的最小 CIE76 ΔE。
  /// 彩色主题取 25（色相可拉开）；纯灰阶主题受物理限制，只能取较低值。
  final double minDeltaE;
}

_Palette _fromPreset(
  String name,
  AppThemeColorScheme preset, {
  required double minDeltaE,
}) {
  final s = preset.status;
  return _Palette(
    name: name,
    minDeltaE: minDeltaE,
    swatches: <String, Color>{
      '0 Unknown': s.status0,
      '1 Learning1': s.status1,
      '2 Learning2': s.status2,
      '3 Learning3': s.status3,
      '4 Learning4': s.status4,
      '5 Learning5': s.status5,
      '98 Ignored': s.status98,
      '99 WellKnown': s.status99,
    },
    background: preset.background.background,
    onSwatch: s.highlightedText,
    playingMark: preset.audio.bookmark,
    pageText: preset.text.primary,
  );
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

// ---------------------------------------------------------------------------

void main() {
  final palettes = <_Palette>[
    _fromPreset('深色主题', darkThemePreset, minDeltaE: 25),
    _fromPreset('浅色主题', lightThemePreset, minDeltaE: 25),
    // 墨水屏主题是纯灰阶，色相维度不可用，ΔE 目标按物理可行性下调到 5。
    _fromPreset('黑白主题', blackAndWhiteThemePreset, minDeltaE: 5),
  ];

  for (final p in palettes) {
    group(p.name, () {
      test('任意两档状态色 CIE76 ΔE 达标', () {
        final keys = p.swatches.keys.toList();
        var minE = double.infinity;
        var worst = '';
        for (var i = 0; i < keys.length; i++) {
          for (var j = i + 1; j < keys.length; j++) {
            final e = deltaE76(p.swatches[keys[i]]!, p.swatches[keys[j]]!);
            if (e < minE) {
              minE = e;
              worst = '${keys[i]} vs ${keys[j]}';
            }
          }
        }
        // ignore: avoid_print
        print('  ${p.name} 最小 ΔE = ${minE.toStringAsFixed(1)}  ($worst)');
        expect(
          minE,
          greaterThanOrEqualTo(p.minDeltaE),
          reason: '最接近的一对是 $worst，ΔE=${minE.toStringAsFixed(1)}，'
              '要求 >= ${p.minDeltaE.toStringAsFixed(0)}',
        );
      });

      test('文字与状态色对比度 >= 4.5', () {
        var minC = double.infinity;
        var worst = '';
        p.swatches.forEach((k, v) {
          final c = contrastRatio(p.onSwatch, v);
          if (c < minC) {
            minC = c;
            worst = k;
          }
        });
        // ignore: avoid_print
        print('  ${p.name} 最低文字对比度 = ${minC.toStringAsFixed(2)}  ($worst)');
        expect(minC, greaterThanOrEqualTo(4.5),
            reason: '$worst 上的文字对比度仅 ${minC.toStringAsFixed(2)}');
      });

      test('状态色与页面底色对比度 >= 3.0', () {
        var minC = double.infinity;
        var worst = '';
        p.swatches.forEach((k, v) {
          final c = contrastRatio(p.background, v);
          if (c < minC) {
            minC = c;
            worst = k;
          }
        });
        // ignore: avoid_print
        print('  ${p.name} 最低底色对比度 = ${minC.toStringAsFixed(2)}  ($worst)');
        expect(minC, greaterThanOrEqualTo(3.0),
            reason: '$worst 与底色 ${_hex(p.background)} 的对比度仅 '
                '${minC.toStringAsFixed(2)}');
      });

      test('同主题内状态色不重复', () {
        final seen = <int, String>{};
        p.swatches.forEach((k, v) {
          final key = v.toARGB32();
          expect(
            seen.containsKey(key),
            isFalse,
            reason: '$k 与 ${seen[key]} 使用了同一个颜色 ${_hex(v)}',
          );
          seen[key] = k;
        });
      });

      test('播放行底色可分辨、其上文字可读', () {
        // 与 theme_extensions.playingLineHighlight 保持同一个配方：
        // audio.bookmark 以 28% 压到页面底色上。
        final highlight = Color.alphaBlend(
          p.playingMark.withValues(alpha: 0.28),
          p.background,
        );
        final dE = deltaE76(highlight, p.background);
        // ignore: avoid_print
        print(
          '  ${p.name} 播放行底色 = ${_hex(highlight)} '
          'ΔE = ${dE.toStringAsFixed(1)} '
          '文字对比度 = ${contrastRatio(p.pageText, highlight).toStringAsFixed(2)}',
        );

        expect(
          dE,
          greaterThanOrEqualTo(20.0),
          reason: '播放行底色 ${_hex(highlight)} 与页面底色 '
              '${_hex(p.background)} 只差 ΔE=${dE.toStringAsFixed(1)}，'
              '读起来会糊在一起',
        );
        expect(
          contrastRatio(p.pageText, highlight),
          greaterThanOrEqualTo(4.5),
          reason: '正文字色 ${_hex(p.pageText)} 在播放行底色 '
              '${_hex(highlight)} 上对比度不足',
        );
      });
    });
  }
}
