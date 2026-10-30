import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/page_keys.dart';

/// 实体按键能触发的阅读动作。
enum HardwareKeyAction { previous, next }

/// 把实体按键翻成阅读动作。
///
/// 目标设备 BOOX Leaf 5C：左侧两枚翻页键在第三方 app 里通常表现为**音量键**，
/// 也可以在文石的「应用优化 → 按键设置」里映射成上一页/下一页
/// （PageUp/PageDown）。两种都接。
///
/// 音量键走不到 Flutter 的键盘事件（系统在窗口层就消费掉了），所以它由
/// [PageKeys] 从原生 `dispatchKeyEvent` 送过来；PageUp/PageDown 和蓝牙
/// 键盘仍然走下面的 [Focus]。两条路都收，但只认一处：
///  * 原生路只看 [Focus] 是否在本控件上 —— IndexedStack 里两个阅读屏同时
///    挂着，没焦点的那屏不能跟着翻页；
///  * 原生路已经在 Activity 层吞掉了音量键，Flutter 侧不会再收到同一个键。
///
/// 刻意不接方向键/空格：那是外接键盘的地盘，抢过来会让蓝牙键盘的用户
/// 翻页翻得莫名其妙。
class HardwareKeyNavigator extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final FocusNode? focusNode;
  final void Function(HardwareKeyAction action) onAction;

  const HardwareKeyNavigator({
    super.key,
    required this.child,
    required this.onAction,
    this.enabled = true,
    this.focusNode,
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
  State<HardwareKeyNavigator> createState() => _HardwareKeyNavigatorState();
}

class _HardwareKeyNavigatorState extends State<HardwareKeyNavigator> {
  VoidCallback? _unsubscribe;
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _subscribe();
  }

  @override
  void didUpdateWidget(HardwareKeyNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      widget.enabled ? _subscribe() : _unsubscribe?.call();
    }
  }

  void _subscribe() {
    _unsubscribe ??= PageKeys.addListener((direction, code) {
      // 同一个 IndexedStack 里可能挂着两个阅读屏，只有持有焦点的那屏翻页。
      debugPrint(
        '[pagekey] native dir=$direction code=$code focus=${_focusNode.hasFocus}',
      );
      if (!_focusNode.hasFocus) return;
      widget.onAction(
        direction > 0 ? HardwareKeyAction.next : HardwareKeyAction.previous,
      );
    });
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Focus(
      // 阅读页里没有可聚焦控件，不自己抢焦点就收不到按键。
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        final action = HardwareKeyNavigator.actionForKeyEvent(event);
        if (action == null) return KeyEventResult.ignored;
        widget.onAction(action);
        // 吞掉：否则系统在翻页之外还顺手把音量调了。
        return KeyEventResult.handled;
      },
      child: widget.child,
    );
  }
}
