package xyz.luan.audioplayers.source

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import xyz.luan.audioplayers.player.FillGateDataSource
import xyz.luan.audioplayers.player.Media3AudioCache
import xyz.luan.audioplayers.player.NetLog
import xyz.luan.audioplayers.player.SoundPoolPlayer
import xyz.luan.audioplayers.player.audioCacheKey
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URL

data class UrlSource(
    val url: String,
    val isLocal: Boolean,
    val headers: Map<String, String>? = null,
) : Source {
    override fun mediaItem(context: Context): MediaItem {
        return if (isLocal) {
            MediaItem.fromUri(Uri.fromFile(File(url.removePrefix("file://"))))
        } else {
            MediaItem.fromUri(url)
        }
    }

    override fun dataSourceFactory(context: Context): DataSource.Factory {
        // 本地文件不进缓存：字节本来就在磁盘上，再抄一份进 SimpleCache 只是白占
        // 空间；而 setSourceDeviceFile 那条路（离线播放、影子跟读裁剪）靠的就是
        // 「文件在哪就在哪读」。
        if (isLocal) return DefaultDataSource.Factory(context)

        // 缓存**只读**：播放器只从里面读，绝不自己往里写。
        //
        // 为什么不能让它写（`setCacheWriteDataSinkFactory(null)` 去掉会踩两
        // 个坑，2026-10-10 真机实测）：
        //
        // 1. 播放器的 DataSpec 是「长度未定」的（`ProgressiveMediaPeriod`
        //    `buildDataSpec` 不设 length，还带
        //    `FLAG_DONT_CACHE_IF_LENGTH_UNKNOWN`）。于是 `CacheDataSink.open`
        //    直接 `dataSpec = null` 关掉写入 —— 一个字节都不会进缓存，
        //    但 `CacheDataSource` 在更上层已经把这个区间的 hole span
        //    **锁住了**，要等它 `close()` 才放。
        // 2. 播放暂停/缓冲区满了之后，load 循环停在 `loadCondition.block()`，
        //    data source 一直开着 —— 那把 hole 锁就一直不放。
        //
        // 结果就是后台补全（`fillAudioCache` 走 `FLAG_BLOCK_ON_CACHE`）永远等
        // 在 `SimpleCache.startReadWrite` 的 `wait()` 里：日志停在
        // `fill still running after 20000ms`，缓存再没长过一个字节。
        //
        // 只读之后 `openNextSource` 走 `cacheWriteDataSource == null` 那条
        // 分支：拿到 hole span 立刻 `releaseHoleSpan` 再读上游，**播放器不再
        // 持有任何缓存锁**，补全永远不会被它挡住。
        //
        // 配上 `FLAG_BLOCK_ON_CACHE`：补全正锁着目标区间时，播放器不绕过缓存
        // 自己再下一遍，而是等补全提交 —— 同一段字节只有一次传输。补全没在跑
        // （没锁）时它就是普通流式播放，行为不变。
        //
        // 但只读也意味着**播放器读到的每一个字节都白读了**：它永远不会写进
        // 缓存。所以"一次传输"完全依赖「补全先拿到锁、播放器全程跟在它后面」，
        // 而这一步的时序由 `AudioCacheFillGate` 保证 —— 见那里的说明。
        val key = audioCacheKey(url)
        val cacheFactory = CacheDataSource.Factory()
            .setCache(Media3AudioCache.get(context))
            .setUpstreamDataSourceFactory(httpDataSourceFactory(headers, "player"))
            .setCacheWriteDataSinkFactory(null)
            .setFlags(CacheDataSource.FLAG_BLOCK_ON_CACHE)
        return DataSource.Factory { FillGateDataSource(cacheFactory.createDataSource(), key) }
    }

    override fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer) {
        soundPoolPlayer.release()
        soundPoolPlayer.urlSource = this
    }

    fun getAudioPathForSoundPool(): String {
        if (isLocal) {
            return url.removePrefix("file://")
        }

        return loadTempFileFromNetwork().absolutePath
    }

    private fun loadTempFileFromNetwork(): File {
        val bytes = downloadUrl(URI.create(url).toURL())
        val tempFile = File.createTempFile("sound", "")
        FileOutputStream(tempFile).use {
            it.write(bytes)
            tempFile.deleteOnExit()
        }
        return tempFile
    }

    private fun downloadUrl(url: URL): ByteArray {
        val outputStream = ByteArrayOutputStream()
        url.openStream().use { stream ->
            val chunk = ByteArray(4096)
            while (true) {
                val bytesRead = stream.read(chunk).takeIf { it > 0 } ?: break
                outputStream.write(chunk, 0, bytesRead)
            }
        }
        return outputStream.toByteArray()
    }

    companion object {
        /**
         * diag.log 的 `ua=` 字段靠它区分「谁拉走了这些字节」。换到 Media3 之前
         * 同一份音频会有两个客户端（`stagefright/1.2` 是 MediaPlayer 在流、
         * `Dart/3.13` 是 app 的 Dio 在预取），这正是重复流量的指纹；现在只剩
         * 播放器一个客户端，这个名字让日志里一眼认得出是谁。
         */
        const val USER_AGENT = "LuteForMobile/ExoPlayer"

        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 60_000

        /**
         * 播放器与后台补全（`fillAudioCache`）共用的上行取数配置。
         *
         * 两处必须完全一致：请求头、UA 只是表面，真正要紧的是**同一个 URL
         * 落到同一个 `CacheDataSource` 键上**（键统一走
         * `player.audioCacheKey`），否则后台补全会在缓存里另开一份，一次传输就
         * 变成两次。放在一个函数里就是为了没有第二个版本。
         *
         * [label] 只影响 `LuteAudioNet` 日志的前缀（`player` / `fill`），不参与
         * 任何请求行为 —— 排查「这次全量传输是谁发的」时靠它。
         *
         * [readTimeoutMs] 只给补全调小（见 `FILL_READ_TIMEOUT_MS`）：播放器全程
         * 只读、要等补全提交下一片才能出声，补全如果卡在一条死连接上，播放器也
         * 跟着卡。默认的 60s 太长。
         *
         * [onTransferStart] 是让行闸门的信号（见 `player.AudioCacheFillGate`）：
         * 「上游开始读」= 缓存锁已经在补全手上。只有补全传它。
         */
        fun httpDataSourceFactory(
            headers: Map<String, String>?,
            label: String,
            readTimeoutMs: Int = READ_TIMEOUT_MS,
            onTransferStart: (() -> Unit)? = null,
        ): DefaultHttpDataSource.Factory = DefaultHttpDataSource.Factory()
            // 本地 fork 的核心补丁：请求头（会话 Cookie / Basic Auth）必须跟着走，
            // 否则多用户服务器会把请求 302 到 /login。
            .setDefaultRequestProperties(headers ?: emptyMap())
            .setUserAgent(USER_AGENT)
            .setConnectTimeoutMs(CONNECT_TIMEOUT_MS)
            .setReadTimeoutMs(readTimeoutMs)
            .setAllowCrossProtocolRedirects(true)
            .setTransferListener(NetLog(label, onTransferStart))
    }
}
