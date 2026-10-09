package xyz.luan.audioplayers

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioAttributes.Builder
import android.media.AudioAttributes.CONTENT_TYPE_MUSIC
import android.media.AudioAttributes.USAGE_MEDIA
import android.media.AudioManager
import android.os.Build
import androidx.annotation.RequiresApi
import java.util.*

data class AudioContextAndroid(
    val isSpeakerphoneOn: Boolean,
    val stayAwake: Boolean,
    val contentType: Int,
    val usageType: Int,
    val audioFocus: Int,
    val audioMode: Int,
) {
    @SuppressLint("InlinedApi") // we are just using numerical constants
    constructor() : this(
        isSpeakerphoneOn = false,
        stayAwake = false,
        contentType = CONTENT_TYPE_MUSIC,
        usageType = USAGE_MEDIA,
        audioFocus = AudioManager.AUDIOFOCUS_GAIN,
        audioMode = AudioManager.MODE_NORMAL,
    )

    // 原来还有一个 setAttributesOnPlayer(MediaPlayer) 和它专用的 getStreamType()
    // （LOLLIPOP 之前按 usage 挑 stream type）。随 MediaPlayer 一起删掉：
    // Media3 用 Builder.setAudioAttributes() / player.setAudioAttributes() 直接吃
    // 这里产出的 AudioAttributes（见 ExoPlayerWrapper），本模块的 minSdk 已是 24，
    // 那条 pre-LOLLIPOP 分支本来也不会再走到。

    @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
    fun buildAttributes(): AudioAttributes {
        return Builder()
            .setUsage(usageType)
            .setContentType(contentType)
            .build()
    }

    override fun hashCode() = Objects.hash(isSpeakerphoneOn, stayAwake, contentType, usageType, audioFocus, audioMode)

    override fun equals(other: Any?) = (other is AudioContextAndroid) &&
        isSpeakerphoneOn == other.isSpeakerphoneOn &&
        stayAwake == other.stayAwake &&
        contentType == other.contentType &&
        usageType == other.usageType &&
        audioFocus == other.audioFocus &&
        audioMode == other.audioMode
}
