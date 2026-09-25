import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 实体按键能触发的阅读动作。
enum HardwareKeyAction { previous, next }

/// 把实体按键翻成阅读动作。
///
/// 目标设备 BOOX Leaf 5C：左侧两枚翻页键在第三方 app 里通常表现为**音量键**，
/// 也可以在文石的「应用优化 → 按键设置」里映射成上一页/下一页
/// （PageUp/PageDown）。两种都接，这台机器到底发哪个由设置页的
/// 「Test hardware keys」实测确认。
///
/// 刻意不接方向键/空格：那是外接键盘的地盘，抢过来会让蓝牙键盘的用户
/// 翻页翻得莫名其妙。
class HardwareKeyNavigator extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final void Function(HardwareKeyAction action) onAction;

  const HardwareKeyNavigator({
    super.key,
    required this.child,
    required this.onAction,
    this.enabled = true,
  });

  static HardwareKeyAction? actionForKeyEvent(KeyEvent event) {
    // 只认按下：连 down 和 up 都处理会一页翻两次。
    if (event is! KeyDownEvent) return null;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.audioVolumeUp ||
        key == LogicalKeyboardKey.pageUp) {
      return HardwareKeyAction.previous;
    }
    if (key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.pageDown) {
      return HardwareKeyAction.next;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      // 阅读页里没有可聚焦控件，不自己抢焦点就收不到按键。
      autofocus: true,
      onKeyEvent: (node, event) {
        final action = actionForKeyEvent(event);
        if (action == null) return KeyEventResult.ignored;
        onAction(action);
        // 吞掉：否则系统在翻页之外还顺手把音量调了。
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
