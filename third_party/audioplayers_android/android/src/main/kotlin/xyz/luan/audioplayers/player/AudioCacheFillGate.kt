package xyz.luan.audioplayers.player

import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * 「谁先拿到缓存锁」的让行闸门 —— 同一份音频只走一次网络的关键。
 *
 * ## 为什么需要它
 *
 * 播放器只读缓存（见 `UrlSource.dataSourceFactory`）、后台补全只写缓存。谁先拿到
 * 目标区间的缓存锁，就决定了这一段字节是谁下的：
 *
 * - **补全先拿到锁** → 播放器在 `SimpleCache.startReadWrite` 里 `wait()`，等补全
 *   `commitFile` 出第一片，再从那一片里读；此后每一片都跟在补全后面。一次传输。
 * - **播放器先拿到锁** → 它拿到的是个洞；只读模式下 `openNextSource` 会立刻
 *   `releaseHoleSpan` 然后**直连上游**把开头几 MB 拉一遍，补全随后从 0 再补
 *   一遍。一次传输变两次 —— 这正是真机 diag.log 里那两条全量
 *   （`200 bs=12980811` + `206 rng=bytes=0-12980810 bs=12980811`）的来源。
 *
 * Dart 侧已经做到「先发 fill、再发 setSourceUrl」，但两边真正开始执行是两个不同
 * 的线程（方法通道回调里再 launch 协程 vs ExoPlayer 的加载线程），先后顺序没有
 * 任何保证。所以在这里显式同步一次：播放器的 data source 在**第一次 open 之前**
 * 等补全「已经拿到锁」的信号。
 *
 * ## 信号是什么
 *
 * 补全的 `CacheDataSource.open()` 里，`startReadWrite`（抢锁）在前、上游
 * `open()`（建连接）在后；上游真正开始读的那一刻会回调 `TransferListener
 * .onTransferStart`。所以「补全的上行传输开始」⟺「锁已经在补全手上」——
 * 一个充分且便宜的信号，不用改 media3 的代码。
 *
 * ## 等不到怎么办
 *
 * 闸门只是优化，不是正确性依赖：补全收工（成功 / 失败 / 被顶掉）会立刻放行，另有
 * [WAIT_TIMEOUT_MS] 兜底。放行之后播放器照常走它的上游 —— 退化成「开头那几 MB
 * 下两遍」，而不是卡住不出声。
 */
object AudioCacheFillGate {

    /**
     * 播放器最多等多久。
     *
     * 补全的 connect 超时是 15s，等满 15s 再放行等于起播多等 15s，太久。这个值要
     * 明显低于「用户会以为卡死了」的门槛；等不到就退化成开头几 MB 的双份流量，
     * 比不出声好得多。
     */
    const val WAIT_TIMEOUT_MS = 6_000L

    private val tickets = ConcurrentHashMap<String, Ticket>()

    /**
     * 一次补全的「放行凭证」。
     *
     * 凭证而不是「按 key 查状态」：补全被后一条顶掉时，旧那条的
     * `onTransferStart` 可能在新凭证登记之后才到 —— 直接按 key 发信号会把新凭证
     * 提前点亮，播放器于是以为锁到手了。凭证把信号绑到具体那一次补全上。
     */
    class Ticket internal constructor(val key: String) {
        private val monitor = Object()
        private var lockHeld = false
        private var finished = false

        /** 补全的上行传输开始了 —— 缓存锁已经在它手上。 */
        internal fun markLockHeld() {
            synchronized(monitor) {
                lockHeld = true
                monitor.notifyAll()
            }
        }

        /** 补全收工（成功 / 失败 / 被顶掉）。等着的播放器可以走了。 */
        internal fun markFinished() {
            synchronized(monitor) {
                finished = true
                monitor.notifyAll()
            }
        }

        /**
         * 阻塞到补全拿到锁、补全收工、或超时。
         *
         * @return true 表示确实等到了锁（播放器该走缓存）。
         */
        fun awaitLockHeld(timeoutMs: Long): Boolean {
            val deadline = System.currentTimeMillis() + timeoutMs
            synchronized(monitor) {
                while (!lockHeld && !finished) {
                    val remaining = deadline - System.currentTimeMillis()
                    if (remaining <= 0) return false
                    try {
                        monitor.wait(remaining)
                    } catch (e: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return false
                    }
                }
                return lockHeld
            }
        }
    }

    /**
     * 补全开工前登记，返回要交给 [finish] 的凭证。
     *
     * **必须在方法通道的回调里同步调用**（不能放在协程体里）：播放器那边靠「登记
     * 已经发生」来决定要不要等，晚一步登记就等于没有闸门。
     */
    fun begin(key: String): Ticket {
        val ticket = Ticket(key)
        tickets[key] = ticket
        return ticket
    }

    /**
     * 补全收工时调用。只摘掉自己那一张凭证 —— 被顶掉的那条收尾时，新的那条可能
     * 已经登记进来了，摘错等于让新的那条失去闸门。
     */
    fun finish(ticket: Ticket) {
        tickets.remove(ticket.key, ticket)
        ticket.markFinished()
    }

    /**
     * 播放器开读前调用：这本书正在补全就等它拿到锁，没人在补全就立刻返回。
     *
     * @return true 表示可以继续（等到了，或本来就不用等）。
     */
    fun awaitIfFilling(key: String, timeoutMs: Long = WAIT_TIMEOUT_MS): Boolean {
        val ticket = tickets[key] ?: return true
        val held = ticket.awaitLockHeld(timeoutMs)
        if (!held) {
            Log.i(NET_TAG, "[player] 等补全拿缓存锁超时（${timeoutMs}ms），改为直连上游: $key")
        }
        return held
    }
}
