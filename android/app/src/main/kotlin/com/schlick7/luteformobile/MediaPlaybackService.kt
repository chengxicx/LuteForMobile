package com.schlick7.luteformobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 播放期间的 mediaPlayback 前台服务。
 *
 * **它不接管播放**：音频仍由 Dart 侧的 audioplayers（Media3 ExoPlayer）和
 * flutter_tts 驱动，这里只做一件事 —— 让进程在锁屏后不被系统冻结。
 *
 * 为什么必须有它（2026-10-19 用户反馈"锁屏就没声音"）：Flutter 层原先在
 * `AppLifecycleState.paused` 主动停播（`player_lifecycle.dart`），放开那条
 * 之后还有第二层坑 —— 锁屏后屏幕熄灭，App 没有前台服务就被划进 cached
 * 进程，CPU 进 suspend、Doze 掐网络。Media3 解出来的音频会断续甚至直接
 * 停住，TTS 则卡在"上一句念完、下一句合成请求发不出去"。
 *
 * 通知刻意做成静默、低优先级、不可划掉：用户选的是"只要不断声"，不需要
 * 播放控制按钮（要做媒体控制得挂 MediaSession，是另一件事）。
 */
class MediaPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "lute_playback_channel"
        const val NOTIFICATION_ID = 1004

        /**
         * 请求（或维持）前台服务。重复调用是安全的：服务已在运行时只会再走
         * 一次 `onStartCommand`，通知被原地更新。
         *
         * Android 12+ 对"从后台启动前台服务"有限制，调用方可能在
         * `paused` 之后的边缘时机（例如锁屏后自动连播下一句）触发它。
         * 那种情况下系统抛 `ForegroundServiceStartNotAllowedException`，
         * 这里吞掉：此时进程通常还没被回收，播放可以继续，下一次在前台
         * 起播时会补上。
         */
        fun start(context: Context) {
            val intent = Intent(context, MediaPlaybackService::class.java)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                android.util.Log.w(
                    "MediaPlaybackService",
                    "start rejected (background start?): ${e.message}"
                )
            }
        }

        /**
         * 停止前台服务。暂停/播完时调用，避免常驻通知赖着不走。
         *
         * 用 `stopService` 而不是再 `startService` 发一个 STOP 动作：后者在
         * Android 8+ 同样是"从后台启动服务"，锁屏后调用会被系统拒绝，
         * 通知就永远清不掉。`stopService` 不受这条限制，前台通知由系统在
         * 服务销毁时一并移除。
         */
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, MediaPlaybackService::class.java))
            } catch (e: Exception) {
                android.util.Log.d(
                    "MediaPlaybackService",
                    "stop ignored: ${e.message}"
                )
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 不要 START_STICKY：进程真被杀掉时没必要重启一个空服务，播放状态
        // 在 Dart 那边，重启也接不上。
        return START_NOT_STICKY
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setContentTitle("Song Mobile")
        .setContentText("Playing in the background")
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setOngoing(true)
        .setSilent(true)
        .setShowWhen(false)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setContentIntent(openAppIntent())
        .build()

    /** 点通知回到 App：与启动器同一个入口，不会新开一份 Activity（singleTask）。 */
    private fun openAppIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Background Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps audio playing while the screen is off"
                setShowBadge(false)
                setSound(null, null)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
