import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/providers/settings_provider.dart';

/// 墨水屏模式总开关（设置 -> Reading -> E-ink mode）。
///
/// 打开后：动画时长归零、去掉水波纹与阴影、加载圈换成静态文案、翻页从
/// 「拖动跟手」改为「左右区域点击」。目标设备是 BOOX Leaf 5C（Kaleido 3），
/// 详见 docs/eink_leaf5c_plan.md。
final einkModeProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider).eInkMode,
);

/// 把开关送进 widget 树，让拿不到 ref 的地方（静态 build 方法、纯
/// StatelessWidget）也能用 context 读到。
class EInkScope extends InheritedWidget {
  final bool enabled;

  const EInkScope({super.key, required this.enabled, required super.child});

  static bool maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EInkScope>()?.enabled ?? false;

  @override
  bool updateShouldNotify(EInkScope oldWidget) => oldWidget.enabled != enabled;
}

extension EInkContextX on BuildContext {
  /// 当前是否处于墨水屏模式。
  bool get eInk => EInkScope.maybeOf(this);
}

/// 墨水屏下把动画时长归零：E-Ink 上任何补间都是一串全屏刷新。
Duration einkDuration(Duration duration, {required bool eInk}) =>
    eInk ? Duration.zero : duration;

/// 墨水屏状态底色（D2①：4 级灰底 + 未学加粗）。
///
/// 彩色状态底在 Kaleido 3 上只有 150ppi，切到黑白模式后 16 灰阶里各种彩底
/// 挤成一团难分彼此。这里把学习状态映射成 4 档灰底：1（新词）最深，
/// 2/3/4 渐浅，5（已学）/ 98 / 99 无底色。深色主题用暗灰系反向渐变。
Color? einkStatusBackground(BuildContext context, String status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (status) {
    case '1':
      return dark ? const Color(0xFF4A4A4A) : const Color(0xFFB4B4B4);
    case '2':
      return dark ? const Color(0xFF3A3A3A) : const Color(0xFFC8C8C8);
    case '3':
      return dark ? const Color(0xFF2E2E2E) : const Color(0xFFDADADA);
    case '4':
      return dark ? const Color(0xFF262626) : const Color(0xFFE8E8E8);
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
