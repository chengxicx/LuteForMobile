import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/providers/settings_provider.dart';
import 'app_theme.dart';

// EInkScope / context.eInk 搬去了只依赖 material 的 eink_scope.dart（取色层
// 要读它，不该顺带把 settings 整条依赖链拖进来）。这里 re-export，原有
// `import 'theme/eink.dart'` 的调用点一行都不用改。
export 'eink_scope.dart';

/// 墨水屏模式总开关（设置 -> Reading -> E-ink mode）。
///
/// 打开后：动画时长归零、去掉水波纹与阴影、加载圈换成静态文案、翻页从
/// 「拖动跟手」改为「左右区域点击」。目标设备是 BOOX Leaf 5C（Kaleido 3），
/// 详见 docs/eink_leaf5c_plan.md。
final einkModeProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider).eInkMode,
);

/// 墨水屏下把动画时长归零：E-Ink 上任何补间都是一串全屏刷新。
Duration einkDuration(Duration duration, {required bool eInk}) =>
    eInk ? Duration.zero : duration;

/// 墨水屏状态底色（Kaleido 3 浅彩方案，2026-10-30 起）。
///
/// 最早一版是 4 级灰底（D2①）：当时认为「彩色状态底在 Kaleido 3 上只有
/// 150ppi，16 灰阶里各种彩底挤成一团难分彼此」。但灰阶方案的相邻档
/// 对比度只有 1.18~1.25:1，真机同样难分；而 Leaf5C 是 Kaleido 3 **彩色**
/// 屏，黑白 300ppi / 彩色 150ppi。帧缓冲实测（2026-10-30 色卡截图逐通道
/// 零偏差）确认 App 端能精确渲染任何 sRGB 色板，于是改为「浅彩底 +
/// 同色系深字」双编码，与服务器用户主题 Boox_Leaf5C.css 完全对齐
/// （App 与 EPUB reader-mode 一套视觉语言）：
///
/// | status | 0(未学) | 1 | 2 | 3 | 4 | 5(已学) |
/// | 底     | 无      | #f5d0d0 | #f5e6b8 | #cde8cd | #cdddf5 | #e2d0f5 |
/// | 字     | #1a4f8b | #7c1d1d | #6b5a00 | #1a5c1a | #1a3d8b | #4a1a8b |
///
/// 浅彩（pastel）= 白光轻微着色，恰好在 150ppi 彩色滤光片的最佳表现区；
/// 深色文字走黑白通道仍是 300ppi。彩底对黑字对比度 14.4~18.0，对同款
/// 深字 5.5~8.0（均超 WCAG AA）；底色色相与文字色相是两条独立通道，
/// 即使面板把颜色冲淡一半也仍可分。残留风险：黄/粉、蓝/紫两对色相在
/// 面板上的真实可分性需真机肉眼验证（screencap 只能验证帧缓冲）。
///
/// 深色主题仍用暗灰系反向渐变（Kaleido 3 深底彩字效果差，墨水屏深色
/// 模式本身也少用）。
Color? einkStatusBackground(BuildContext context, String status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!dark) {
    switch (status) {
      case '1':
        return const Color(0xFFF5D0D0);
      case '2':
        return const Color(0xFFF5E6B8);
      case '3':
        return const Color(0xFFCDE8CD);
      case '4':
        return const Color(0xFFCDDDF5);
      case '5':
        return const Color(0xFFE2D0F5);
      default:
        return null;
    }
  }
  switch (status) {
    case '1':
      return const Color(0xFF5C5C5C);
    case '2':
      return const Color(0xFF464646);
    case '3':
      return const Color(0xFF343434);
    case '4':
      return const Color(0xFF262626);
    default:
      return null;
  }
}

/// 墨水屏状态文字色。浅色主题配同色系深字（与 [einkStatusBackground]
/// 的浅彩底成对，见上表）；98/99 返回 null 落回正文色。深色主题返回
/// null（沿用灰底 + 正文色）。
Color? einkStatusText(BuildContext context, String status) {
  if (Theme.of(context).brightness == Brightness.dark) return null;
  switch (status) {
    case '0':
      return const Color(0xFF1A4F8B);
    case '1':
      return const Color(0xFF7C1D1D);
    case '2':
      return const Color(0xFF6B5A00);
    case '3':
      return const Color(0xFF1A5C1A);
    case '4':
      return const Color(0xFF1A3D8B);
    case '5':
      return const Color(0xFF4A1A8B);
    default:
      return null;
  }
}

/// 未学（0/1）加粗：0 无底、靠深蓝粗体醒目；1 浅彩底再补一层保险。
bool einkStatusBold(String status) => status == '0' || status == '1';

/// 页面转场直接返回 child：默认转场是一段 300ms 的淡入/位移，在墨水屏上
/// 就是十几次全屏刷新。
class NoPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// 把自定义色板换成「纯白纸 + 纯黑墨」。
///
/// 与 `applyEInkTheme` 里的 scaffold/surface 覆盖是同一件事的两半：那一半管
/// 走 Material `ThemeData` 的组件，这一半管直接读 `context.appColorScheme`
/// 的组件（播放条卡面、词卡、句子翻译、容器底色…）。真机采样能直接看到差别
/// —— 只改 ThemeData 时整屏还有 15% 的 `#fffbfe`。
List<ThemeExtension<dynamic>> _eInkPaperExtensions(
  Iterable<ThemeExtension<dynamic>> source,
) {
  return source.map<ThemeExtension<dynamic>>((ext) {
    if (ext is! AppThemeColorExtension) return ext;
    final scheme = ext.colorScheme;
    return ext.copyWith(
      colorScheme: scheme.copyWith(
        background: scheme.background.copyWith(
          background: const Color(0xFFFFFFFF),
          surface: const Color(0xFFFFFFFF),
          surfaceContainerHighest: const Color(0xFFFFFFFF),
        ),
        text: scheme.text.copyWith(
          primary: const Color(0xFF000000),
          headline: const Color(0xFF000000),
        ),
      ),
    );
  }).toList();
}

/// 墨水屏模式下的主题覆盖：扒掉一切会连续重绘的视觉效果。
///
/// 水波纹（点击后 300ms 的扩散）、点击高亮、悬停色、卡片阴影 —— 在 LCD 上
/// 是"反馈"，在 E-Ink 上是一串全屏刷新。
ThemeData applyEInkTheme(ThemeData base) {
  // 墨水屏纸张：最白底 + 最黑字。只对**浅色**主题生效 —— 深色主题在墨水屏
  // 上走的是另一套（灰阶反相），把它刷白等于把夜间阅读直接毁掉。
  // 这一层管的是 App 原生渲染的那些书（纯文本、漫画文字层、列表、词卡），
  // WebView 里的书由 `eink_paper.dart` 的注入样式负责，两边纸色取同一个
  // #ffffff / #000000，翻页时不会有色差。
  final light = base.brightness == Brightness.light;
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    cardTheme: base.cardTheme.copyWith(
      elevation: 0,
      color: light ? const Color(0xFFFFFFFF) : null,
    ),
    scaffoldBackgroundColor: light ? const Color(0xFFFFFFFF) : null,
    canvasColor: light ? const Color(0xFFFFFFFF) : null,
    colorScheme: light
        ? base.colorScheme.copyWith(
            surface: const Color(0xFFFFFFFF),
            onSurface: const Color(0xFF000000),
            // M3 的卡片/对话框/底部条读的是 surfaceContainer* 这一族，不是
            // surface 本身。少写一个，列表里的书卡就还是 #fffbfe —— 真机
            // 采样时它占了整屏 60%，是"背景不够白"的主要来源。
            surfaceDim: const Color(0xFFFFFFFF),
            surfaceBright: const Color(0xFFFFFFFF),
            surfaceContainerLowest: const Color(0xFFFFFFFF),
            surfaceContainerLow: const Color(0xFFFFFFFF),
            surfaceContainer: const Color(0xFFFFFFFF),
            surfaceContainerHigh: const Color(0xFFFFFFFF),
            surfaceContainerHighest: const Color(0xFFFFFFFF),
          )
        : null,
    textTheme: light
        ? base.textTheme.apply(
            bodyColor: const Color(0xFF000000),
            displayColor: const Color(0xFF000000),
          )
        : null,
    // 自定义色板（`context.appColorScheme`）单独换一份：播放条卡面、词卡、
    // 各种 Container 直接读它，不经过 ThemeData，只改 surface 压不住 ——
    // 真机采样里那 15% 的 #fffbfe 就是它。白纸要落在这一层才算白。
    extensions: light
        ? _eInkPaperExtensions(base.extensions.values)
        : base.extensions.values.toList(),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: NoPageTransitionsBuilder(),
        TargetPlatform.iOS: NoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: NoPageTransitionsBuilder(),
        TargetPlatform.linux: NoPageTransitionsBuilder(),
        TargetPlatform.macOS: NoPageTransitionsBuilder(),
        TargetPlatform.windows: NoPageTransitionsBuilder(),
      },
    ),
  );
}
