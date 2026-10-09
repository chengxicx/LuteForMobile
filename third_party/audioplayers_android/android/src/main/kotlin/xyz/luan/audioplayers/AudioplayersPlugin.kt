package xyz.luan.audioplayers

import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.ContentMetadataMutations
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import xyz.luan.audioplayers.player.AudioCacheFillGate
import xyz.luan.audioplayers.player.CACHE_TAG
import xyz.luan.audioplayers.player.Media3AudioCache
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.player.audioCacheKey
import xyz.luan.audioplayers.player.cachedCoverage
import xyz.luan.audioplayers.source.BytesSource
import xyz.luan.audioplayers.source.UrlSource
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

typealias FlutterHandler = (call: MethodCall, response: MethodChannel.Result) -> Unit

/** 导出缓存文件时的拷贝缓冲；64KB 是 flash 上顺序写比较稳的一档。 */
private const val EXPORT_BUFFER_BYTES = 64 * 1024

/** 补全卡住多久之后打一行日志（撞上别人的锁时可能要等）。 */
private const val FILL_STALL_REPORT_MS = 20_000L

/**
 * 补全写缓存时的分片大小。
 *
 * `CacheDataSink` 只在分片写满时才 `commitFile`，那一刻这段数据才对别的读者可见
 * （也是播放器阻塞等锁时被唤醒的时机）。播放器全程只读、只从缓存拿字节，所以
 * **首声延迟 ≈ 补全的 TTFB + 下载一片的时间**，分片大小直接决定它。
 *
 * 默认 5MB 太粗；media3 自己建议的下限是 2MB。这里再往下压到 1MB：2MB 在慢网
 * 下就是好几秒的静默，1MB 把这段砍一半，代价是缓存文件数翻倍（一本 13MB 的书
 * 13 片）—— 256MB 的 LRU 上限下完全吃得下，media3 那句 "below the minimum
 * recommended value" 只是 `Log.w`，不影响正确性。
 */
private const val FILL_FRAGMENT_BYTES = 1L * 1024 * 1024

/**
 * 补全专用的上行读超时。
 *
 * 播放器全程只读、**要等补全提交下一片才能出声**，所以补全卡在一条死连接上时，
 * 播放器会一起卡在 `SimpleCache.startReadWrite` 的 `wait()` 里 —— 没有异常、
 * 没有回调，从界面上看就是"转圈不出来"。默认的 60s 太长，20s 足够判死一条
 * 连接（这是"完全没有字节到达"的时长，不是总时长）。
 */
private const val FILL_READ_TIMEOUT_MS = 20_000

class AudioplayersPlugin : FlutterPlugin {
    private lateinit var methods: MethodChannel
    private lateinit var globalMethods: MethodChannel
    private lateinit var globalEvents: EventHandler
    private lateinit var context: Context
    private lateinit var binaryMessenger: BinaryMessenger
    private lateinit var soundPoolManager: SoundPoolManager

    private val players = ConcurrentHashMap<String, WrappedPlayer>()
    private var defaultAudioContext = AudioContextAndroid()

    /**
     * 跑缓存补全/导出的协程域。这两个动作都是几十 MB 的 IO，绝不能占着主线程，
     * 也不能挂在任何一个 player 上 —— 它们与播放器实例无关。
     */
    private val cacheScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 当前在跑的补全。同一时刻只留一条，见 [fillAudioCache]。 */
    private var cacheFillJob: Job? = null

    /**
     * 当前那条补全的 writer。
     *
     * 光 cancel 协程是不够的：`CacheWriter.cache()` 是阻塞循环，协程取消它看不见。
     * 必须让 writer 自己停（它会抛 `InterruptedIOException` 出来）。
     */
    private var cacheWriter: CacheWriter? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        binaryMessenger = binding.binaryMessenger
        soundPoolManager = SoundPoolManager(this)
        methods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers")
        methods.setMethodCallHandler { call, response -> safeCall(call, response, ::methodHandler) }
        globalMethods = MethodChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global")
        globalMethods.setMethodCallHandler { call, response -> safeCall(call, response, ::globalMethodHandler) }
        globalEvents = EventHandler(EventChannel(binding.binaryMessenger, "xyz.luan/audioplayers.global/events"))
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        players.values.forEach { it.dispose() }
        players.clear()
        soundPoolManager.dispose()
        globalEvents.dispose()
        cancelCacheFill()
        cacheScope.cancel()
        Media3AudioCache.release()
    }

    private fun safeCall(
        call: MethodCall,
        response: MethodChannel.Result,
        handler: FlutterHandler,
    ) {
        try {
            handler(call, response)
        } catch (e: Throwable) {
            response.error("Unexpected AndroidAudioError", e.message, e)
        }
    }

    private fun globalMethodHandler(call: MethodCall, response: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                players.values.forEach { it.dispose() }
                players.clear()
            }

            "setAudioContext" -> {
                val audioManager = getAudioManager()
                audioManager.mode = defaultAudioContext.audioMode
                audioManager.isSpeakerphoneOn = defaultAudioContext.isSpeakerphoneOn

                defaultAudioContext = call.audioContext()
            }

            "emitLog" -> {
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalLog(message)
            }

            "emitError" -> {
                val code = call.argument<String>("code") ?: error("code is required")
                val message = call.argument<String>("message") ?: error("message is required")
                handleGlobalError(code, message, null)
            }

            // 下面两个是本地 fork 新增的：让 Dart 侧能用「播放器正在读的那份
            // 磁盘缓存」补全离线文件，而不是另开一条 HTTP 再下一遍。
            "fillAudioCache" -> {
                fillAudioCache(call, response)
                return
            }

            "exportAudioCache" -> {
                exportAudioCache(call, response)
                return
            }

            // 用户离开阅读页/换书时叫停在跑的那条补全：传输在原生侧，Dart 取消
            // 不了它，不叫停的话那几十 MB 还会在后台默默下完。
            "cancelAudioCacheFill" -> cancelCacheFill()

            else -> {
                response.notImplemented()
                return
            }
        }

        response.success(1)
    }

    /**
     * 把 [url] 整份补进 [Media3AudioCache]。
     *
     * 与播放共用同一份缓存，所以「用户已经听过的那一段」不会再下一遍 —— 这正是
     * 换掉 MediaPlayer 要解决的问题。播放器侧的 `CacheDataSource` 与这里的
     * `CacheWriter` 走的是同一个 `DefaultHttpDataSource` 配置（
     * [UrlSource.httpDataSourceFactory]），键才会落在同一处。
     *
     * 同一时刻只跑一条：换书/换页时上一条必须停，否则旧书的几十 MB 还在后台跟
     * 新书抢带宽（Dart 侧 `_cancelPrefetch` 的语义，因为传输在原生侧跑，只能
     * 在这里做）。
     *
     * 结果：`true` 补完；`false` 被新的一条顶掉了（调用方当"取消"处理，不是失败）。
     */
    private fun fillAudioCache(call: MethodCall, response: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: error("url is required")
        val headers = call.argument<Map<String, String>>("headers")
        // Dart 侧为了判断「本地那份是不是完整的」本来就要发一次
        // `Range: bytes=0-0` 探测（`_probeAudioSize`）。让它把结果带过来，
        // 原生侧就不用再探一次 —— 少一个请求，更要紧的是补全能**在拿到锁之前
        // 一次网络往返都不花**：播放器还在装配时补全已经把目标区间锁上了，
        // 播放器的第一次读就直接落在缓存里，开头那几 MB 不会被下两遍。
        val knownTotal = call.argument<Number>("totalLength")?.toLong()
        val replied = AtomicBoolean(false)

        fun reply(value: Any?) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { response.success(value) }
            }
        }

        val key = audioCacheKey(url)
        cancelCacheFill()
        // **在方法通道的回调里同步登记**，不能挪进协程体：播放器的 data source 靠
        // 「这本书有凭证」来决定要不要让行（见 [AudioCacheFillGate]）。协程真正开跑
        // 可能晚几十毫秒，而 `setSourceUrl` 的 prepare 就在这之后 —— 登记晚一步
        // 等于没有闸门。
        val ticket = AudioCacheFillGate.begin(key)
        val job = cacheScope.launch {
            try {
                val cache = Media3AudioCache.get(context)
                val recorded = ContentMetadata.getContentLength(cache.getContentMetadata(key))
                // Dart 没带长度过来（离线、探测失败）时才自己探一次。
                val total = knownTotal ?: probeTotalLength(url, headers)
                Log.i(
                    CACHE_TAG,
                    "fill start $key recordedLen=$recorded total=$total " +
                        "(fromDart=${knownTotal != null}) cached=${cachedCoverage(cache, key)}",
                )
                if (total != null && recorded != total) {
                    Log.i(CACHE_TAG, "fill correct content length $recorded -> $total")
                    cache.applyContentMetadataMutations(
                        key,
                        ContentMetadataMutations.setContentLength(ContentMetadataMutations(), total),
                    )
                }

                // **必须是 downloading 变体**，它带 `FLAG_BLOCK_ON_CACHE`。
                //
                // `createDataSource()` 不带这个 flag，于是 `CacheDataSource` 在
                // `openNextSource` 里走 `startReadWriteNonBlocking`：目标区间一旦
                // 正被别人锁着，`lockRange` 失败 → 返回 null → 它直接落到
                // `nextDataSource = upstreamDataSource` 那条分支，**绕过
                // TeeDataSource**：字节读进来就扔掉，缓存一个字节都不涨，而
                // `CacheWriter.cache()` 照样正常返回。
                //
                // 现在播放器是只读的（见 [UrlSource.dataSourceFactory]），正常情况
                // 下没人跟补全抢锁；但被顶掉的那条补全可能还捏着一瞬间的锁，带上
                // flag 让它等而不是把字节扔掉，代价为零。
                //
                // 同时自己给一个 `CacheDataSink`，把分片大小压到
                // [FILL_FRAGMENT_BYTES]：`CacheDataSink` 只在**分片写满**时才
                // `commitFile`，而 `commitFile` 才是「这段进缓存了、别人可以读
                // 了」的那一刻，也正是播放器从 `startReadWrite` 的 `wait()` 里被
                // 唤醒的时刻。
                //
                // `onTransferStart` 把让行闸门点亮：`CacheDataSource.open()` 里
                // 抢锁在前、上游开读在后，所以这一回调一到就说明锁已在补全手上。
                val dataSource = CacheDataSource.Factory()
                    .setCache(cache)
                    .setUpstreamDataSourceFactory(
                        UrlSource.httpDataSourceFactory(
                            headers,
                            "fill",
                            readTimeoutMs = FILL_READ_TIMEOUT_MS,
                            onTransferStart = ticket::markLockHeld,
                        ),
                    )
                    .setCacheWriteDataSinkFactory(
                        CacheDataSink.Factory()
                            .setCache(cache)
                            .setFragmentSize(FILL_FRAGMENT_BYTES),
                    )
                    .createDataSourceForDownloading()
                // media3 1.8 的 CacheWriter 只有 4 参构造；临时缓冲与进度回调都
                // 交给它自己（null = 用默认的 128KB 缓冲、不报进度）。
                // cache() 自己会跳过缓存里已有的区间 —— 这正是「从播放器下过的
                // 地方接着补」的落点。
                //
                // 长度已知时**显式带上**：`CacheWriter` 就不用去猜
                // `endPosition`（猜错就是提前收工），而且 `CacheDataSink` 拿到
                // 有界请求后 `commitFile` 的长度校验才对得上。
                //
                // `FLAG_ALLOW_CACHE_FRAGMENTATION` 是让上面那个分片生效的
                // 开关（`CacheDataSink.open` 里按这个 flag 决定
                // `dataSpecFragmentSize`，没有它一律 `Long.MAX_VALUE` = 不分片）。
                val spec = DataSpec.Builder()
                    .setUri(Uri.parse(url))
                    .setFlags(DataSpec.FLAG_ALLOW_CACHE_FRAGMENTATION)
                    .apply { if (total != null) setLength(total) }
                    .build()
                val writer = CacheWriter(dataSource, spec, null, null)
                cacheWriter = writer
                try {
                    writer.cache()
                } finally {
                    // 只有这条还是"当前那条"时才清：被顶掉的那条收尾时，新的那条
                    // 可能已经把自己的 writer 放进来了，清掉它等于让取消失效。
                    if (cacheWriter === writer) cacheWriter = null
                }
                Log.i(CACHE_TAG, "fill done $key cached=${cachedCoverage(cache, key)}")
                // 补全"没报错"不等于补全到位：`CacheWriter` 只要走到它认为的结尾
                // 就会正常返回。长度已知时必须自己核一遍覆盖到哪 —— 差一截就
                // 当作失败（Dart 会重试），别让它一路走到"导出成功但文件是半截"。
                val end = cache.getCachedSpans(key).lastOrNull()?.let { it.position + it.length } ?: 0L
                if (total != null && end != total) {
                    throw IOException("补全后缓存只覆盖到 $end / $total 字节")
                }
                reply(true)
            } catch (e: CancellationException) {
                reply(false)
                throw e
            } catch (e: InterruptedIOException) {
                // CacheWriter.cancel() 的产物：被后一条顶掉了，不是失败。
                Log.i(CACHE_TAG, "fill canceled: $url")
                reply(false)
            } catch (e: Throwable) {
                Log.i(CACHE_TAG, "fill failed: $url ${e.message}")
                if (replied.compareAndSet(false, true)) {
                    mainHandler.post {
                        response.error("AndroidAudioError", e.message, e)
                    }
                }
            }
        }
        // 协程真正结束时（正常 / 异常 / 还没开跑就被取消）放行等着的播放器。
        // 放行的语义是「别再等了」：补全成功则缓存已齐、直接读得到；失败则让它
        // 退回直连上游。两条路都不会卡住不出声。
        job.invokeOnCompletion { cause ->
            AudioCacheFillGate.finish(ticket)
            // launch 可能还没开始执行就被下一条 cancel 掉，那样协程体一次都不跑，
            // response 永远不回 —— Dart 侧会永久挂住。这里兜底。
            if (cause is CancellationException) reply(false)
        }
        // 到点还没收工就打一行日志，顺手把媒体栈的线程状态倒出来。
        //
        // `SimpleCache.startReadWrite` 撞上别人的锁时会 `wait()` 住，从外面看
        // 就是「补全再没动静」；这台设备是 release 包、`run-as` 不可用、
        // `kill -3` 又被拒，抓不到 Java 栈。所以自己在代码里留一手：真卡住时
        // 日志直接告诉我们是卡在 `startReadWrite` 的 `wait()`、卡在
        // `CacheWriter` 的读循环，还是卡在网络读上。
        cacheScope.launch {
            delay(FILL_STALL_REPORT_MS)
            if (job.isActive) {
                Log.i(CACHE_TAG, "fill still running after ${FILL_STALL_REPORT_MS}ms: $url")
                dumpMedia3Threads("fill stalled")
            }
        }
        cacheFillJob = job
    }

    /** 叫停在跑的那条补全（换书、换页、离开阅读页、引擎卸载）。 */
    private fun cancelCacheFill() {
        cacheWriter?.cancel()
        cacheWriter = null
        cacheFillJob?.cancel()
        cacheFillJob = null
    }

    /**
     * 把已缓存的 [url] 导出成普通文件 [destPath]（先写 `.part` 再改名）。
     *
     * 离线播放与影子跟读裁剪要的是一个**真的文件**，而 SimpleCache 存的是分片。
     * 导出而不是重下：字节已经在缓存里了，这一步只花本地 IO。
     *
     * **只读缓存，不许回源** —— 调用方负责先 [fillAudioCache]。回源会让这里
     * 悄悄再走一次网络，正是要消灭的那份流量。
     *
     * 直接按 `Cache.getCachedSpans` 拼文件，而不是再走一遍 `CacheDataSource`：
     *
     * - `CacheDataSource` 的读法依赖 flag 语义（`createDataSource()` 撞上被锁的
     *   区间会绕缓存直连上游；`createDataSourceForRemovingDownload()` 的
     *   upstream 是个 `PlaceholderDataSource`，真读到洞会抛
     *   `UnsupportedOperationException`），错一处就从"导不出"变成"又下一遍"；
     * - span 拼法是确定性的本地 IO，而且**洞在哪一段能直接报出来**，
     *   排查时不用再猜（原来的报错只有一句"缓存里没有完整内容"）。
     *
     * 返回导出的字节数。
     */
    private fun exportAudioCache(call: MethodCall, response: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: error("url is required")
        val destPath = call.argument<String>("destPath") ?: error("destPath is required")

        cacheScope.launch {
            try {
                val cache = Media3AudioCache.get(context)
                val key = audioCacheKey(url)
                val spans = cache.getCachedSpans(key)
                Log.i(
                    CACHE_TAG,
                    "export $key spans=${spans.size} cached=${cachedCoverage(cache, key)}",
                )

                val target = File(destPath)
                // 与 Dart 侧断点续传共用 `.part` 约定：半截文件永远不会被当成
                // 完整缓存用（`AudioCacheService` 也会按过期残片回收它）。
                val tmp = File("$destPath.part")
                target.parentFile?.mkdirs()

                var written = 0L
                tmp.outputStream().use { out ->
                    val buffer = ByteArray(EXPORT_BUFFER_BYTES)
                    for (span in spans) {
                        val file = span.file ?: continue
                        if (!span.isCached) continue
                        // 分片之间可能有洞（播放器还在写、或补全被掐）。只有从 0
                        // 严丝合缝拼到底才能当完整文件用：差一个字节，离线播放和
                        // 影子跟读就会读到一个坏文件，宁可失败。
                        if (span.position != written) {
                            throw IOException(
                                "缓存里 $key 缺 bytes=$written-${span.position - 1}" +
                                    "（已拼 $written 字节；${cachedCoverage(cache, key)}）",
                            )
                        }
                        file.inputStream().use { input ->
                            var remaining = span.length
                            while (remaining > 0) {
                                val want = minOf(buffer.size.toLong(), remaining).toInt()
                                val read = input.read(buffer, 0, want)
                                if (read < 0) {
                                    throw IOException(
                                        "缓存分片 ${file.name} 比索引里记的短：还差 $remaining 字节",
                                    )
                                }
                                out.write(buffer, 0, read)
                                remaining -= read
                                written += read
                            }
                        }
                    }
                }

                // 拼得连续还不够：还要和记录的总长对上。缓存只覆盖了前半截时，
                // 拼出来的会是一个"连续但短"的文件 —— 那种文件能播、能裁剪，但
                // 播到一半就没了，比导出失败更难查。宁可在这里报错。
                val recorded = ContentMetadata.getContentLength(cache.getContentMetadata(key))
                if (recorded != C.LENGTH_UNSET.toLong() && written != recorded) {
                    throw IOException("拼出来的文件 $written 字节，与缓存记录的 $recorded 不符")
                }

                if (!tmp.renameTo(target)) {
                    tmp.copyTo(target, overwrite = true)
                    tmp.delete()
                }
                Log.i(CACHE_TAG, "export done $key bytes=$written")
                mainHandler.post { response.success(written) }
            } catch (e: Throwable) {
                // 半截的 `.part` 没有任何续传价值（导出是纯本地拷贝，每次都从头
                // 拼），留着只会占几十 MB，所以失败就删掉。
                runCatching { File("$destPath.part").delete() }
                Log.i(CACHE_TAG, "export failed: $url ${e.message}")
                mainHandler.post {
                    response.error("AndroidAudioError", e.message, e)
                }
            }
        }
    }

    /**
     * 用一次 `Range: bytes=0-0` 问出远端总长度。
     *
     * **只在 Dart 没把长度带过来时用**（离线、Dart 侧探测失败）。正常情况下
     * `fillAudioCache` 直接收 Dart `_probeAudioSize` 的结果 —— 那一步 Dart 本来
     * 就要做，重复探一次不但多一个请求，还会让补全在拿到缓存锁之前先花掉一个网络
     * 往返，播放器于是抢在前面把开头几 MB 从上游拉了一遍（[AudioCacheFillGate]
     * 的等待是有限的，不会为这一步一直等下去）。
     *
     * 为什么不能直接信缓存里的内容长度：`CacheDataSource` 在读上游「提前结束」时会
     * **用当前读到的位置覆盖它**（`setNoBytesRemainingAndMaybeStoreLength`），一次
     * 被掐断的读就能把它写成半截长度。真机证据（2026-10-10 04:30:39 diag.log）：
     * 同一条 URL 的请求上界是 `bytes=47064-2743168`，而服务端那个文件是 12980811
     * 字节 —— 客户端的"长度"是错的。
     *
     * 这个错长度有两层后果，都很致命：
     * - `CacheWriter.cache()` 以它当 `endPosition` → 走到 2743169 就"补完了"，
     *   缓存永远缺后面那 10MB，导出每次都失败；
     * - `SimpleCache.commitFile` 有一条 `position + length <= contentLength` 的
     *   断言 → 分片一旦超出这个错长度就抛异常，`CacheDataSink` 顺手把刚下好的
     *   整份文件删掉，白下。
     *
     * （播放器改成只读之后这条覆盖路径就够不着元数据了 —— 见
     * [UrlSource.dataSourceFactory]；缓存目录也换了名字把这批脏值整批作废，见
     * `Media3AudioCache.DIR_NAME`。这里保留探测是作为 Dart 侧长度缺失时的兜底。）
     *
     * 返回 null 表示问不到（离线 / 服务端不支持 Range）—— 那就退回「让
     * `CacheWriter` 自己走到真正的 EOF」。
     */
    private fun probeTotalLength(url: String, headers: Map<String, String>?): Long? {
        // 同一个短超时：这一步跑在"补全还没拿到锁"的窗口里，播放器正等在那儿，
        // 让一条死连接把两边一起拖 60s 没有意义。
        val source = UrlSource.httpDataSourceFactory(headers, "probe", FILL_READ_TIMEOUT_MS)
            .createDataSource()
        return try {
            source.open(
                DataSpec.Builder()
                    .setUri(Uri.parse(url))
                    .setPosition(0)
                    .setLength(1)
                    .build(),
            )
            source.responseHeaders.entries
                .firstOrNull { it.key.equals("Content-Range", ignoreCase = true) }
                ?.value?.firstOrNull()
                ?.substringAfterLast('/')
                ?.trim()
                ?.toLongOrNull()
        } catch (e: Throwable) {
            Log.i(CACHE_TAG, "probe failed: $url ${e.message}")
            null
        } finally {
            runCatching { source.close() }
        }
    }

    /**
     * 把涉及媒体栈的线程栈打进 logcat。
     *
     * 这台测试机装的是 release 包：`run-as` 说 "package not debuggable"，`kill -3`
     * 又被 SELinux 挡掉（`Operation not permitted`），出了死锁只能靠自己在代码里
     * 留证据。只在「补全超时还没结束」这条罕见路径上调用，不影响正常流程。
     *
     * 过滤条件放宽到 `xyz.luan` + `media3` + `SimpleCache`：调用方自己的协程体
     * （`AudioplayersPlugin`）往往就在栈里，一眼能看出是卡在 `wait()`、
     * 卡在 `CacheWriter` 的读循环，还是卡在网络读。
     */
    private fun dumpMedia3Threads(reason: String) {
        try {
            for ((thread, frames) in Thread.getAllStackTraces()) {
                val interesting = frames.filter { frame ->
                    val name = frame.className
                    name.startsWith("androidx.media3") ||
                        name.startsWith("xyz.luan.audioplayers") ||
                        name.contains("CacheWriter")
                }
                for (frame in interesting) {
                    Log.i(CACHE_TAG, "$reason thread=${thread.name} state=${thread.state} at $frame")
                }
            }
        } catch (e: Throwable) {
            Log.i(CACHE_TAG, "$reason stack dump failed: ${e.message}")
        }
    }

    private fun methodHandler(call: MethodCall, response: MethodChannel.Result) {
        val playerId = call.argument<String>("playerId") ?: return
        if (call.method == "create") {
            val eventHandler = EventHandler(EventChannel(binaryMessenger, "xyz.luan/audioplayers/events/$playerId"))
            players[playerId] = WrappedPlayer(this, eventHandler, defaultAudioContext.copy(), soundPoolManager)
            response.success(1)
            return
        }
        val player = getPlayer(playerId)
        try {
            when (call.method) {
                "setSourceUrl" -> {
                    val url = call.argument<String>("url") ?: error("url is required")
                    val isLocal = call.argument<Boolean>("isLocal") ?: false
                    val headers = call.argument<Map<String, String>>("headers")
                    try {
                        player.source = UrlSource(url, isLocal, headers)
                    } catch (e: FileNotFoundException) {
                        response.error(
                            "AndroidAudioError",
                            "Failed to set source. For troubleshooting, see: " +
                                "https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md",
                            e,
                        )
                        return
                    }
                }

                "setSourceBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: error("bytes are required")
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        error("BytesSource is not supported on Android <= M")
                    }
                    player.source = BytesSource(bytes)
                }

                "resume" -> player.play()
                "pause" -> player.pause()
                "stop" -> player.stop()
                "release" -> player.release()
                "seek" -> {
                    val position = call.argument<Int>("position") ?: error("position is required")
                    player.seek(position)
                }

                "setVolume" -> {
                    val volume = call.argument<Double>("volume") ?: error("volume is required")
                    player.volume = volume.toFloat()
                }

                "setBalance" -> {
                    val balance = call.argument<Double>("balance") ?: error("balance is required")
                    player.balance = balance.toFloat()
                }

                "setPlaybackRate" -> {
                    val rate = call.argument<Double>("playbackRate") ?: error("playbackRate is required")
                    player.rate = rate.toFloat()
                }

                "getDuration" -> {
                    response.success(player.getDuration())
                    return
                }

                "getCurrentPosition" -> {
                    response.success(player.getCurrentPosition())
                    return
                }

                "setReleaseMode" -> {
                    val releaseMode = call.enumArgument<ReleaseMode>("releaseMode") ?: error("releaseMode is required")
                    player.releaseMode = releaseMode
                }

                "setPlayerMode" -> {
                    val playerMode = call.enumArgument<PlayerMode>("playerMode") ?: error("playerMode is required")
                    player.playerMode = playerMode
                }

                "setAudioContext" -> {
                    val audioContext = call.audioContext()
                    player.updateAudioContext(audioContext)
                }

                "emitLog" -> {
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleLog(message)
                }

                "emitError" -> {
                    val code = call.argument<String>("code") ?: error("code is required")
                    val message = call.argument<String>("message") ?: error("message is required")
                    player.handleError(code, message, null)
                }

                "dispose" -> {
                    player.dispose()
                    players.remove(playerId)
                }

                else -> {
                    response.notImplemented()
                    return
                }
            }
            response.success(1)
        } catch (e: Exception) {
            response.error("AndroidAudioError", e.message, e)
        }
    }

    private fun getPlayer(playerId: String): WrappedPlayer {
        return players[playerId] ?: error("Player has not yet been created or has already been disposed.")
    }

    fun getApplicationContext(): Context {
        return context.applicationContext
    }

    fun getAudioManager(): AudioManager {
        return context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    fun handleDuration(player: WrappedPlayer) {
        player.eventHandler.success(
            "audio.onDuration",
            hashMapOf("value" to (player.getDuration() ?: 0)),
        )
    }

    fun handleComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onComplete")
    }

    fun handlePrepared(player: WrappedPlayer, isPrepared: Boolean) {
        player.eventHandler.success("audio.onPrepared", hashMapOf("value" to isPrepared))
    }

    fun handleLog(player: WrappedPlayer, message: String) {
        player.eventHandler.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleGlobalLog(message: String) {
        globalEvents.success("audio.onLog", hashMapOf("value" to message))
    }

    fun handleError(player: WrappedPlayer, errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        player.eventHandler.error(errorCode, errorMessage, errorDetails)
    }

    fun handleGlobalError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        globalEvents.error(errorCode, errorMessage, errorDetails)
    }

    fun handleSeekComplete(player: WrappedPlayer) {
        player.eventHandler.success("audio.onSeekComplete")
    }
}

private inline fun <reified T : Enum<T>> MethodCall.enumArgument(name: String): T? {
    val enumName = argument<String>(name) ?: return null
    return enumValueOf<T>(enumName.split('.').last().toConstantCase())
}

fun String.toConstantCase(): String {
    return replace(Regex("(.)(\\p{Upper})"), "$1_$2").replace(Regex("(.) (.)"), "$1_$2").uppercase()
}

private fun MethodCall.audioContext(): AudioContextAndroid {
    return AudioContextAndroid(
        isSpeakerphoneOn = argument<Boolean>("isSpeakerphoneOn") ?: error("isSpeakerphoneOn is required"),
        stayAwake = argument<Boolean>("stayAwake") ?: error("stayAwake is required"),
        contentType = argument<Int>("contentType") ?: error("contentType is required"),
        usageType = argument<Int>("usageType") ?: error("usageType is required"),
        audioFocus = argument<Int>("audioFocus") ?: error("audioFocus is required"),
        audioMode = argument<Int>("audioMode") ?: error("audioMode is required"),
    )
}

class EventHandler(private val eventChannel: EventChannel) : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    init {
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun success(method: String, arguments: Map<String, Any> = HashMap()) {
        eventSink?.success(arguments + Pair("event", method))
    }

    fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        eventSink?.error(errorCode, errorMessage, errorDetails)
    }

    fun dispose() {
        eventSink?.let {
            it.endOfStream()
            onCancel(null)
        }
        eventChannel.setStreamHandler(null)
    }
}
