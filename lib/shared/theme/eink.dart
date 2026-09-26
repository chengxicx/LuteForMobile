import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/providers/settings_provider.dart';

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

/// 墨水屏状态底色（D2①：4 级灰底 + 未学加粗）。
///
/// 彩色状态底在 Kaleido 3 上只有 150ppi，切到黑白模式后 16 灰阶里各种彩底
/// 挤成一团难分彼此。这里把学习状态映射成 4 档灰底：1（新词）最深，
/// 2/3/4 渐浅，5（已学）/ 98 / 99 无底色。深色主题用暗灰系反向渐变。
///
/// 取值按 16 级灰阶校准（每级 255/17 ≈ 17）：浅色 1/2/3/4 分别落在
/// 第 10/11/12/13 级，页底为第 15/16 级 —— 最早一版 status 2/3 用
/// C8/DA，量化后挤进第 12/13 级，跟白底只差一两档，双击置 3 后基本
/// 看不出来（2026-09-25 真机反馈）。现在各状态间隔至少 2 级灰。
Color? einkStatusBackground(BuildContext context, String status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (status) {
    case '1':
      return dark ? const Color(0xFF5C5C5C) : const Color(0xFFA8A8A8);
    case '2':
      return dark ? const Color(0xFF464646) : const Color(0xFFBEBEBE);
    case '3':
      return dark ? const Color(0xFF343434) : const Color(0xFFCCCCCC);
    case '4':
      return dark ? const Color(0xFF262626) : const Color(0xFFE0E0E0);
    default:
      return null;
  }
}

/// 灰阶下底色只剩深浅一个维度，新词（status 1）再加粗补一层区分。
bool einkStatusBold(String status) => status == '1';

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

/// 墨水屏模式下的主题覆盖：扒掉一切会连续重绘的视觉效果。
///
/// 水波纹（点击后 300ms 的扩散）、点击高亮、悬停色、卡片阴影 —— 在 LCD 上
/// 是"反馈"，在 E-Ink 上是一串全屏刷新。
ThemeData applyEInkTheme(ThemeData base) {
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    cardTheme: base.cardTheme.copyWith(elevation: 0),
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
