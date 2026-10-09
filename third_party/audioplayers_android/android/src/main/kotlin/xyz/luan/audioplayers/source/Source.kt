package xyz.luan.audioplayers.source

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSource
import xyz.luan.audioplayers.player.SoundPoolPlayer

/**
 * 一份可播放的媒体。
 *
 * 原来这里只有 `setForMediaPlayer(context, mediaPlayer)` —— 直接把 URL 交给
 * `android.media.MediaPlayer`。换成 Media3 之后播放器要的是两样东西：一个
 * [MediaItem]（播什么）和一个 [DataSource.Factory]（怎么取），接口于是拆成
 * 对应的两个方法。
 *
 * **远端实现必须把 `Media3AudioCache` 包进 `CacheDataSource`**，这是「播放与
 * 后台补全共用一次传输」的全部依据 —— 漏掉它就退回两份流量。
 */
interface Source {
    /** 要播放的媒体项。 */
    fun mediaItem(context: Context): MediaItem

    /** 取数工厂。 */
    fun dataSourceFactory(context: Context): DataSource.Factory

    fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer)
}
