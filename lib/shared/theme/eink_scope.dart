import 'package:flutter/material.dart';

/// 墨水屏模式开关的传递层。
///
/// 刻意只有 material 一个依赖：`theme_extensions.dart` 要在取色时读它，
/// 而 `eink.dart` 里的 provider 又依赖 settings / riverpod —— 把 scope 单独
/// 拆出来，取色层就不必把整条 settings 依赖链拖进 import 图。
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
