package xyz.luan.audioplayers.player

import android.content.Context
import android.net.Uri
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * 缓存键：播放器（`CacheDataSource`）、后台补全（`CacheWriter`）、导出
 * （`Cache.getCachedSpans`）三处必须落在同一个键上 —— 差一个字符就是缓存里两份
 * 数据，「一次传输」立刻变两次。所以只留这一个实现，谁都不许自己拼。
 *
 * 与 `CacheDataSource` 内部用的是同一个工厂（`CacheKeyFactory.DEFAULT`
 * = `dataSpec.key ?: uri.toString()`），不是"等价"而是同一段代码。
 */
internal fun audioCacheKey(url: String): String =
    CacheKeyFactory.DEFAULT.buildCacheKey(DataSpec(Uri.parse(url)))

/**
 * 播放器与后台补全共用的磁盘缓存。
 *
 * 存在的理由只有一个：**同一份音频只走一次网络**。Media3 的
 * `CacheDataSource` 一边读一边把字节写进这里，后台的 `CacheWriter` 又从这里
 * 已有的位置接着往下补 —— 于是「点了立刻出声」和「补一份完整文件以便离线 /
 * 影子跟读裁剪」不再各自拉一遍（换之前是 MediaPlayer 流一份、Dio 再下一份，
 * 2026-10-10 diag.log 里 book 273 的 6.4MB 出现了两次）。
 *
 * 目录刻意放在 app 的 cache 目录下（`<cacheDir>/media3_audio`），与用户可见的
 * 离线音频库（`<cacheDir>/audiobooks`，见 Dart 侧 `AudioCacheService`）分开：
 *
 * - 这里是**传输层缓存**，随时可以被 LRU 淘汰，不承诺任何东西；
 * - 那边是**离线库**，用户能看见体积、能按书清、永远不被自动回收。
 *
 * 上限取 256MB：够装几本有声书，让「听了一半的几十 MB」不会立刻被挤掉而触发
 * 重下，又不会让这块不可见的占用无限膨胀。
 */
object Media3AudioCache {
    /**
     * 目录名带版本号，**换语义就换名字**。
     *
     * `media3_audio` → `media3_audio_v2`（2026-10-10）：旧版本里播放器是可写的，
     * 一次被掐断的读会让 `CacheDataSource.setNoBytesRemainingAndMaybeStoreLength`
     * 把「内容长度」写成当前读位置（diag.log 里 book 274 的记录长度变成了
     * 2743169，真实是 12980811），`CacheWriter` 于是只补到那儿就收工。
     *
     * `media3_audio_v2` → `media3_audio_v3`（同日）：v2 那几轮真机跑出来的是
     * 「播放器抢在补全前面直连上游」的组合 —— 缓存里留下了一批**来源不明的**
     * 分片和错长度元数据（`pos=2743169` 那个读位置就是这么来的）。v3 起播放器
     * 只读、补全先拿锁（[AudioCacheFillGate]），语义又变了一次，同样整批作废最
     * 干净：旧目录留在磁盘上由 LRU / 系统清理回收，不再被读。
     */
    const val DIR_NAME = "media3_audio_v3"

    private const val MAX_BYTES = 256L * 1024 * 1024

    @Volatile
    private var instance: SimpleCache? = null

    /** 拿到（必要时创建）进程内唯一的缓存实例。线程安全。 */
    fun get(context: Context): SimpleCache {
        instance?.let { return it }
        return synchronized(this) {
            instance ?: run {
                val appContext = context.applicationContext
                SimpleCache(
                    File(appContext.cacheDir, DIR_NAME),
                    LeastRecentlyUsedCacheEvictor(MAX_BYTES),
                    StandaloneDatabaseProvider(appContext),
                ).also { instance = it }
            }
        }
    }

    /** 进程/引擎卸载时释放。之后 [get] 会重新建一个（缓存内容留在磁盘上）。 */
    fun release() {
        synchronized(this) {
            try {
                instance?.release()
            } catch (_: Throwable) {
                // 释放失败没有补救手段，也不该让引擎卸载崩掉。
            }
            instance = null
        }
    }
}
