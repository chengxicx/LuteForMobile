package xyz.luan.audioplayers.player

import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache

/**
 * 缓存/网络的诊断日志。
 *
 * 「谁开了连接、下了多少字节」在 nginx 的 diag.log 里只能看到一个 `ua=`，而播放器
 * 与后台补全共用同一个 UA；「缓存里到底有哪些区间」在 Dart 侧根本看不到（release
 * 包里 `debugPrint` 也不一定进得了 logcat）。所以这两件事固定打在这两个 tag 上：
 *
 *     adb logcat -s LuteAudioNet -s LuteAudioCache
 *
 * 只在排查重复流量/补全失败时打开看，常驻的 `Log.i` 代价可以忽略。
 */
const val NET_TAG = "LuteAudioNet"
const val CACHE_TAG = "LuteAudioCache"

/** 每累计读到这么多字节打一行进度（只在排查时看，粒度粗一点免得刷屏）。 */
private const val PROGRESS_REPORT_BYTES = 1L * 1024 * 1024

/**
 * 每次真正开一条上行连接时打一行。
 *
 * [label] 用来区分调用方（`player` / `fill`）：`pos`/`len` 与 diag.log 的 `rng=`
 * 是一一对应的，两条日志拼起来才能回答「这次全量传输是谁发的」。
 *
 * [onTransferStart] 是给 [AudioCacheFillGate] 用的信号：`CacheDataSource.open()`
 * 里「抢缓存锁」在前、「上游开始读」在后，所以这一回调一到就说明锁已经到手了。
 * 它**不是**日志用的，名字放在这里只是因为 `TransferListener` 是现成的钩子。
 */
class NetLog(
    private val label: String,
    private val onTransferStart: (() -> Unit)? = null,
) : TransferListener {

    /** 这条 data source 累计读到的字节，用来按 [PROGRESS_REPORT_BYTES] 节流打点。 */
    private var transferred = 0L
    private var nextReportAt = PROGRESS_REPORT_BYTES

    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit

    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        Log.i(NET_TAG, "[$label] open pos=${dataSpec.position} len=${lenText(dataSpec.length)}")
        onTransferStart?.invoke()
    }

    override fun onBytesTransferred(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
        bytesTransferred: Int,
    ) {
        transferred += bytesTransferred
        if (transferred >= nextReportAt) {
            // `pos` 是这条请求的起点、`total` 是本次累计读到的量。两条一起看就能
            // 判断「补全是在推进，还是停在某一片上不动」—— 播放器等锁时最需要它。
            Log.i(NET_TAG, "[$label] read pos=${dataSpec.position} total=$transferred")
            nextReportAt = transferred + PROGRESS_REPORT_BYTES
        }
    }

    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        Log.i(NET_TAG, "[$label] close pos=${dataSpec.position} len=${lenText(dataSpec.length)}")
    }
}

internal fun lenText(length: Long): String =
    if (length == C.LENGTH_UNSET.toLong()) "unset" else length.toString()

/**
 * 把缓存里已有的分片区间打成一行，例如
 * `end=2743169 [0, 2743169)`。
 *
 * 判断「补全有没有真的写进缓存」只能看这个：`CacheWriter.cache()` 正常返回不代表
 * 缓存涨了（它可能整段绕过缓存直连上游）。
 */
internal fun cachedCoverage(cache: Cache, key: String): String {
    val spans = cache.getCachedSpans(key)
    if (spans.isEmpty()) return "end=0 (空)"
    val sb = StringBuilder()
    for (span in spans) {
        sb.append(" [").append(span.position).append(", ")
            .append(span.position + span.length).append(')')
    }
    return "end=${spans.last().let { it.position + it.length }}$sb"
}
