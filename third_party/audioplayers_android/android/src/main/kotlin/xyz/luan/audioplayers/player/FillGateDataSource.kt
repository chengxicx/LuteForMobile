package xyz.luan.audioplayers.player

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * 播放器 data source 外面的让行闸门（见 [AudioCacheFillGate]）。
 *
 * 只多包一层 `open`：在真正去缓存里找数据之前，先等这本书的后台补全把缓存锁抓
 * 到手。`read` / `close` / 响应头全部直接透传 —— 不多一次拷贝、不改任何语义，
 * 所以「补全没在跑」时这层等于不存在。
 *
 * 放在 `CacheDataSource` **外面**（而不是塞进它的 upstream）是刻意的：
 * `CacheDataSource.open()` 一进去就 `startReadWrite` 抢锁，要拦就得拦在它前面。
 */
class FillGateDataSource(
    private val delegate: DataSource,
    private val cacheKey: String,
) : DataSource {

    override fun open(dataSpec: DataSpec): Long {
        AudioCacheFillGate.awaitIfFilling(cacheKey)
        return delegate.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        delegate.read(buffer, offset, length)

    override fun getUri(): Uri? = delegate.getUri()

    override fun getResponseHeaders(): Map<String, List<String>> = delegate.getResponseHeaders()

    override fun close() {
        delegate.close()
    }

    override fun addTransferListener(transferListener: TransferListener) {
        delegate.addTransferListener(transferListener)
    }
}
