package com.schlick7.luteformobile

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Dart 侧控制 [MediaPlaybackService] 的通道。
 *
 * 两个方法，语义都是**幂等**的：`start` / `stop`。引用计数放在 Dart 那边
 * （见 `lib/core/services/playback_foreground_service.dart`），因为 MP3 与
 * 整页朗读 TTS 是两条独立的播放链路，谁先谁后 Kotlin 这边不关心。
 */
class MediaPlaybackBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "com.schlick7.luteformobile/media_playback"
    }

    fun registerMethodChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    MediaPlaybackService.start(context)
                    result.success(true)
                }
                "stop" -> {
                    MediaPlaybackService.stop(context)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
