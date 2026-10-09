package xyz.luan.audioplayers.source

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import xyz.luan.audioplayers.player.SoundPoolPlayer

/**
 * 直接把内存里的字节当媒体播。
 *
 * 普通 class 而不是 data class：字段是 `ByteArray`，data class 生成的
 * equals/hashCode 按引用比，读的人容易以为能按内容去重 —— 显式写成引用语义。
 */
class BytesSource(
    val bytes: ByteArray,
) : Source {
    override fun mediaItem(context: Context): MediaItem = MediaItem.fromUri(BYTES_URI)

    override fun dataSourceFactory(context: Context): DataSource.Factory =
        DataSource.Factory { ByteArrayDataSource(bytes) }

    override fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer) {
        error("Bytes sources are not supported on LOW_LATENCY mode yet.")
    }

    companion object {
        /** 只为给 [MediaItem] 一个非空 URI；字节由 [dataSourceFactory] 提供，不读它。 */
        private const val BYTES_URI = "audioplayers://bytes"
    }
}
