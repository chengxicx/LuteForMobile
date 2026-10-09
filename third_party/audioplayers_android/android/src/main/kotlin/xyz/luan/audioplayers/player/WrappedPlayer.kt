package xyz.luan.audioplayers.player

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.PlayerMode
import xyz.luan.audioplayers.PlayerMode.LOW_LATENCY
import xyz.luan.audioplayers.PlayerMode.MEDIA_PLAYER
import xyz.luan.audioplayers.ReleaseMode
import xyz.luan.audioplayers.source.Source
import kotlin.math.min

// For some reason this cannot be accessed from MediaPlayer.MEDIA_ERROR_SYSTEM
private const val MEDIA_ERROR_SYSTEM = -2147483648

class WrappedPlayer internal constructor(
    private val ref: AudioplayersPlugin,
    val eventHandler: EventHandler,
    var context: AudioContextAndroid,
    private val soundPoolManager: SoundPoolManager,
) {
    private var player: PlayerWrapper? = null

    var source: Source? = null
        set(value) {
            if (field != value) {
                if (value != null) {
                    val player = getOrCreatePlayer()
                    player.setSource(value)
                    player.configAndPrepare()
                } else {
                    released = true
                    prepared = false
                    playing = false
                    player?.release()
                }
                field = value
            } else {
                ref.handlePrepared(this, true)
            }
        }

    var volume = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(value, balance)
                }
            }
        }

    var balance = 0.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(volume, value)
                }
            }
        }

    var rate = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (playing) {
                    player?.setRate(value)
                }
            }
        }

    var releaseMode = ReleaseMode.RELEASE
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setLooping(isLooping)
                }
            }
        }

    val isLooping: Boolean
        get() = releaseMode == ReleaseMode.LOOP

    var playerMode: PlayerMode = MEDIA_PLAYER
        set(value) {
            if (field != value) {
                field = value

                // if the player exists, we need to re-create it from scratch;
                // this will probably cause music to pause for a second
                player?.let {
                    shouldSeekTo = maybeGetCurrentPosition()
                    prepared = false
                    it.release()
                }
                initPlayer()
            }
        }

    var released = true

    var prepared: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                ref.handlePrepared(this, value)
            }
        }

    var playing = false
    var shouldSeekTo = -1

    private val focusManager = FocusManager.create(
        this,
        onGranted = {
            // Check if in playing state, as the focus can also be gained e.g. after a phone call, even if not playing.
            if (playing) {
                player?.start()
            }
        },
        onLoss = { isTransient ->
            if (isTransient) {
                // Do not check or set playing state, as the state should be recovered after granting focus again.
                player?.pause()
            } else {
                // Audio focus won't be recovered
                pause()
            }
        },
    )

    private fun maybeGetCurrentPosition(): Int {
        // for Sound Pool, we can't get current position, so we just start over
        return runCatching { player?.getCurrentPosition().takeUnless { it == 0 } }.getOrNull() ?: -1
    }

    private fun getOrCreatePlayer(): PlayerWrapper {
        val currentPlayer = player
        return if (released || currentPlayer == null) {
            createPlayer().also {
                player = it
                released = false
            }
        } else if (prepared) {
            currentPlayer.also {
                it.reset()
                prepared = false
            }
        } else {
            currentPlayer
        }
    }

    fun updateAudioContext(audioContext: AudioContextAndroid) {
        if (context == audioContext) {
            return
        }
        if (context.audioFocus != AudioManager.AUDIOFOCUS_NONE &&
            audioContext.audioFocus == AudioManager.AUDIOFOCUS_NONE
        ) {
            focusManager.handleStop()
        }
        this.context = audioContext.copy()

        // AudioManager values are set globally
        audioManager.mode = context.audioMode
        audioManager.isSpeakerphoneOn = context.isSpeakerphoneOn

        player?.let { p ->
            p.stop()
            prepared = false
            // Context is only applied, once the player.reset() was called
            p.updateContext(context)
            source?.let {
                p.setSource(it)
                p.configAndPrepare()
            }
        }
    }

    // Getters

    /**
     * Returns the duration of the media in milliseconds, if available.
     */
    fun getDuration(): Int? {
        return if (prepared) player?.getDuration() else null
    }

    /**
     * Returns the current position of the playback in milliseconds, if available.
     */
    fun getCurrentPosition(): Int? {
        return if (prepared) player?.getCurrentPosition() else null
    }

    val applicationContext: Context
        get() = ref.getApplicationContext()

    val audioManager: AudioManager
        get() = ref.getAudioManager()

    /**
     * Playback handling methods
     */
    fun play() {
        if (!playing && !released) {
            playing = true
            if (player == null) {
                initPlayer()
            } else if (prepared) {
                requestFocusAndStart()
            }
        }
    }

    // Try to get audio focus and then start.
    private fun requestFocusAndStart() {
        focusManager.maybeRequestAudioFocus()
    }

    fun stop() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (releaseMode != ReleaseMode.RELEASE) {
            pause()
            if (prepared) {
                if (player?.isLiveStream() == true) {
                    player?.stop()
                    prepared = false
                    player?.prepare()
                } else {
                    // MediaPlayer does not allow to call player.seekTo after calling player.stop
                    seek(0)
                }
            }
        } else {
            release()
        }
    }

    fun release() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (playing) {
            player?.stop()
        }

        // Setting source to null will reset released, prepared and playing
        // and also calls player.release()
        source = null
        player = null
    }

    fun pause() {
        if (playing) {
            playing = false
            if (prepared) {
                player?.pause()
            }
        }
    }

    // seek operations cannot be called until after
    // the player is ready.
    fun seek(position: Int) {
        shouldSeekTo = if (prepared && player?.isLiveStream() != true) {
            player?.seekTo(position)
            -1
        } else {
            position
        }
    }

    /**
     * Player callbacks
     */
    fun onPrepared() {
        prepared = true
        ref.handleDuration(this)
        if (playing) {
            requestFocusAndStart()
        }
        if (shouldSeekTo >= 0 && player?.isLiveStream() != true) {
            player?.seekTo(shouldSeekTo)
        }
    }

    fun onCompletion() {
        if (releaseMode != ReleaseMode.LOOP) {
            stop()
        }
        ref.handleComplete(this)
    }

    @Suppress("UNUSED_PARAMETER")
    fun onBuffering(percent: Int) {
        // TODO(luan): expose this as a stream
    }

    fun onSeekComplete() {
        ref.handleSeekComplete(this)
    }

    fun handleLog(message: String) {
        ref.handleLog(this, message)
    }

    fun handleError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        ref.handleError(this, errorCode, errorMessage, errorDetails)
    }

    fun onError(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        // 出错后播放器不再处于 prepared：不置回去的话，上层会继续往一个坏掉的
        // 播放器下发 play/seek，全部静默无效。（原 MediaPlayer 版在这里比的是
        // what/extra 两个 int，Media3 报的是 PlaybackException，语义一样。）
        prepared = false
        handleError(errorCode, errorMessage, errorDetails)
    }

    /**
     * Internal logic. Private methods
     */

    /**
     * Create new player
     */
    private fun createPlayer(): PlayerWrapper {
        return when (playerMode) {
            // MEDIA_PLAYER 是默认模式，实现已从 android.media.MediaPlayer 换成
            // Media3/ExoPlayer（见 ExoPlayerWrapper）—— 为的是能共用一份磁盘缓存，
            // 让「流式起播」和「补一份完整文件」只走一次网络。
            MEDIA_PLAYER -> ExoPlayerWrapper(this)
            LOW_LATENCY -> SoundPoolPlayer(this, soundPoolManager)
        }
    }

    /**
     * Create new player, assign and configure source
     */
    private fun initPlayer() {
        val player = createPlayer()
        // Need to set player before calling prepare, as onPrepared may is called before player is assigned
        this.player = player
        source?.let {
            player.setSource(it)
            player.configAndPrepare()
        }
    }

    private fun PlayerWrapper.configAndPrepare() {
        setVolumeAndBalance(volume, balance)
        setLooping(isLooping)
        prepare()
    }

    private fun PlayerWrapper.setVolumeAndBalance(volume: Float, balance: Float) {
        val leftVolume = min(1f, 1f - balance) * volume
        val rightVolume = min(1f, 1f + balance) * volume
        setVolume(leftVolume, rightVolume)
    }

    fun dispose() {
        release()
        eventHandler.dispose()
    }
}
