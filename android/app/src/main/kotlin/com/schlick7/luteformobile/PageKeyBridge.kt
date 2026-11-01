package com.schlick7.luteformobile

import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 墨水屏设备的物理翻页键桥。
///
/// BOOX Leaf 这类设备的侧键默认发**音量键**（KEYCODE_VOLUME_UP/DOWN），
/// 在文石的「按键设置」里也能改成上一页/下一页（KEYCODE_PAGE_UP/DOWN）。
///
/// 两种都必须在这里拦，不能交给 Flutter 的键盘事件：
///  * 音量键在 `PhoneWindow.dispatchKeyEvent` 里就被系统消费去调音量了，
///    根本走不到 FlutterView —— 这是"翻页键按了没反应"的根因；
///  * 章节是 WebView（platform view），它有 Android 焦点时也会自己吃掉
///    按键。
///
/// 在 Activity 的 `dispatchKeyEvent` 里先取走，再回传 Dart。Dart 侧没有
/// 订阅者时（不在阅读页）原样放行，音量键恢复调音量。
class PageKeyBridge {
    private var channel: MethodChannel? = null

    @Volatile
    private var enabled = false

    fun registerMethodChannel(flutterEngine: FlutterEngine) {
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 返回 true 表示这个按键当翻页用掉了，不再交给窗口/系统。 */
    fun handleKeyEvent(event: KeyEvent): Boolean {
        val direction = directionOf(event.keyCode)
        if (direction == 0) return false
        android.util.Log.d(
            "PageKey",
            "key=${event.keyCode} action=${event.action} repeat=${event.repeatCount} enabled=$enabled"
        )
        if (!enabled) return false
        // 抬起也要吞：否则系统仍会拿松开事件去调音量。
        if (event.action == KeyEvent.ACTION_UP) return true
        if (event.action != KeyEvent.ACTION_DOWN) return false
        // 长按不连翻：一页一屏，连翻会直接跳过好几屏。
        if (event.repeatCount > 0) return true
        channel?.invokeMethod(
            "pageKey",
            mapOf("direction" to direction, "keyCode" to event.keyCode)
        )
        return true
    }

    /** -1 上一页 / +1 下一页 / 0 与本桥无关。 */
    private fun directionOf(keyCode: Int): Int = when (keyCode) {
        KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_PAGE_UP -> -1
        KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_PAGE_DOWN -> 1
        else -> 0
    }

    companion object {
        const val CHANNEL = "com.schlick7.luteformobile/page_keys"
    }
}
