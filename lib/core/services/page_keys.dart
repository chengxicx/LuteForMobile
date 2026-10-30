import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 墨水屏设备的物理翻页键。
///
/// 侧键在系统看来是音量键，`PhoneWindow` 会在 Activity 之前把它们消费掉，
/// 所以接不到 Flutter 的键盘事件里；章节又是 WebView（platform view），
/// 有 Android 焦点时也会自己吃按键。原生侧因此用 `dispatchKeyEvent` 先取
/// 走（`PageKeyBridge.kt`），再从这里分发给订阅者。
///
/// 没有订阅者时原生侧原样放行 —— 不在阅读页时音量键还是音量键。
class PageKeys {
  static const MethodChannel _channel = MethodChannel(
    'com.schlick7.luteformobile/page_keys',
  );

  static final List<void Function(int direction, int keyCode)> _listeners = [];
  static bool _wired = false;

  static void _ensureWired() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'pageKey') return null;
      final args = (call.arguments as Map?) ?? const {};
      final direction = (args['direction'] as num?)?.toInt() ?? 0;
      final keyCode = (args['keyCode'] as num?)?.toInt() ?? 0;
      if (direction == 0) return null;
      lastEvent.value =
          'keyCode=$keyCode  ${direction < 0 ? 'previous' : 'next'}';
      // 回调里可能有人退订（翻页会重建页面），先拷一份再遍历。
      for (final listener in List.of(_listeners)) {
        listener(direction, keyCode);
      }
      return null;
    });
  }

  /// 订阅按键；返回退订函数。
  ///
  /// 订阅期间音量键被当作翻页键用掉，系统音量请走快捷面板。
  static VoidCallback addListener(
    void Function(int direction, int keyCode) listener,
  ) {
    _ensureWired();
    _listeners.add(listener);
    _syncEnabled();
    return () {
      _listeners.remove(listener);
      _syncEnabled();
    };
  }

  /// 最近一次收到的物理键，供设置页的按键诊断显示。音量键走不到 Flutter
  /// 的键盘事件，那里只能靠这里的记录确认机器发的是哪个键。
  static final ValueNotifier<String?> lastEvent = ValueNotifier<String?>(null);

  static void _syncEnabled() {
    _channel
        .invokeMethod<void>('setEnabled', {'enabled': _listeners.isNotEmpty})
        .catchError((Object _) {
          // 非 Android（或还没挂上引擎）：静默失败，按键本就不可用。
        });
  }
}
