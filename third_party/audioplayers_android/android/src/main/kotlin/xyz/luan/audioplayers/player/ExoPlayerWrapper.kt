package xyz.luan.audioplayers.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.source.Source

/**
 * `PlayerWrapper` 的 Media3/ExoPlayer 实现，取代原来的 `MediaPlayerWrapper`。
 *
 * 换它的唯一原因是磁盘缓存：`android.media.MediaPlayer` 没有任何可共享的
 * 缓存，而 app 既要流式起播、又要手上有一份完整文件（离线播放 + 影子跟读
 * 裁剪），只能两路各下一遍。Media3 的 `CacheDataSource`（见 [Source] 的
 * 远端实现）让这两件事读写同一份缓存。
 *
 * 对外契约与 `MediaPlayerWrapper` 保持一致 —— `PlayerWrapper` 接口、
 * `WrappedPlayer` 的状态机（prepared / playing / shouldSeekTo）、
 * `onPrepared` / `onCompletion` / `onSeekComplete` 三个回调的时机都不变，
 * 上层 Dart 代码无感。
 */
class ExoPlayerWrapper(
    private val wrappedPlayer: WrappedPlayer,
) : PlayerWrapper {
    private val mainHandler = Handler(Looper.getMainLooper())

    private val player: ExoPlayer = ExoPlayer.Builder(wrappedPlayer.applicationContext)
        // handleAudioFocus = false：音频焦点由 WrappedPlayer 的 FocusManager 统一
        // 申请/释放，交给 ExoPlayer 会变成两套互相抢（申请两次、丢一次焦点）。
        .setAudioAttributes(media3Attributes(wrappedPlayer.context), false)
        .build()

    /** 当前装配的媒体源；`prepare()` 时才真正交给播放器。 */
    private var source: Source? = null

    /** `STATE_READY` 会随缓冲反复到达，`onPrepared` 只认第一次。 */
    private var preparedOnce = false

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_READY -> if (!preparedOnce) {
                    preparedOnce = true
                    wrappedPlayer.onPrepared()
                }

                Player.STATE_ENDED -> wrappedPlayer.onCompletion()

                else -> Unit
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            preparedOnce = false
            wrappedPlayer.onError(error.errorCodeName, error.message, error.cause)
        }
    }

    init {
        player.addListener(listener)
    }

    override fun getDuration(): Int? {
        val duration = player.duration
        // MediaPlayer 用 -1 表示未知，Media3 用 C.TIME_UNSET；对外统一成 null。
        return if (duration == C.TIME_UNSET || duration <= 0) null else duration.toInt()
    }

    override fun getCurrentPosition(): Int = player.currentPosition.coerceAtLeast(0L).toInt()

    override fun isLiveStream(): Boolean = player.isCurrentMediaItemLive

    override fun start() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun stop() {
        player.stop()
    }

    override fun seekTo(position: Int) {
        player.seekTo(position.coerceAtLeast(0).toLong())
        // Media3 没有「seek 完成」回调 —— seek 是对时间线的立即操作。Dart 侧
        // AudioPlayer.seek() 会等 audio.onSeekComplete，所以这里补一个；post
        // 出去保证它排在方法返回值之后到达，不会早于监听方注册。
        mainHandler.post { wrappedPlayer.onSeekComplete() }
    }

    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        // Media3 的 Player 只有单值 volume，没有声道平衡。app 从不设 balance，
        // 正常路径上左右相等，取平均是精确值；真用了 balance 也只是退化成单声道
        // 音量，不会静音或爆音。
        player.volume = ((leftVolume + rightVolume) / 2f).coerceIn(0f, 1f)
    }

    override fun setRate(rate: Float) {
        player.setPlaybackSpeed(rate)
    }

    override fun setLooping(looping: Boolean) {
        player.repeatMode =
            if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    override fun updateContext(context: AudioContextAndroid) {
        // Media3 允许直接改属性，不用像 MediaPlayer 那样 reset 后重建。
        player.setAudioAttributes(media3Attributes(context), false)
    }

    override fun setSource(source: Source) {
        this.source = source
        preparedOnce = false
    }

    override fun prepare() {
        val source = this.source ?: return
        player.setMediaSource(buildMediaSource(source))
        // 起播由 WrappedPlayer.play() → start() 控制；prepare() 自己不该出声，
        // 否则 setSource 之后会未经请求直接开播（原来是 MediaPlayer 的默认行为，
        // 这里必须显式关掉，因为 playWhenReady 会跨 setMediaSource 保留）。
        player.playWhenReady = false
        player.prepare()
    }

    override fun release() {
        player.removeListener(listener)
        player.release()
    }

    override fun reset() {
        player.stop()
        player.clearMediaItems()
        preparedOnce = false
    }

    private fun buildMediaSource(source: Source): MediaSource {
        val context: Context = wrappedPlayer.applicationContext
        return DefaultMediaSourceFactory(source.dataSourceFactory(context))
            .createMediaSource(source.mediaItem(context))
    }

    /**
     * `android.media.AudioAttributes` → `androidx.media3.common.AudioAttributes`。
     *
     * 两个同名不同包的类，Media3 只认后者。usage/contentType 的整型常量在两边的
     * 取值是一致的（Media3 刻意对齐了 framework），所以直接搬。
     */
    private fun media3Attributes(
        context: AudioContextAndroid,
    ): androidx.media3.common.AudioAttributes =
        androidx.media3.common.AudioAttributes.Builder()
            .setUsage(context.usageType)
            .setContentType(context.contentType)
            .build()
}
