/// 音频缓存**断点续传**的纯判定 —— 没有 IO、没有插件，可以直接测。
///
/// 为什么需要它：有声书的音频动辄几十 MB，而服务端的
/// `/useraudio/stream/<id>` 是支持 Range 的（`_send_audio_range_aware`）。
/// 原来的 `_downloadAudioToFile` 一失败就删掉 `.part` 从头再来，
/// 2026-10-10 的 diag.log 里就出现过：64MB 的音频下到 `bs=52826112` 被掐，
/// 下一次 loadAudio 又从 0 下了一遍（`bs=64231987`），白扔 50 多 MB。
///
/// 续传的唯一风险是"接错地方"：把整份内容追加到半截文件后面，会得到一个
/// 长度看起来对、内容却是坏的缓存。所以追加必须满足两个条件 ——
/// 服务端确实按我们给的起点回了 206，且 `Content-Range` 的起点和我们手上的
/// 字节数一致。任一条不满足就退回"从头重写"。
library;

/// `Content-Range: bytes 100-999/1000` 的起点（100）；拿不到返回 null。
int? contentRangeStart(String? contentRange) {
  final m = _contentRange.firstMatch(contentRange?.trim() ?? '');
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// `Content-Range: bytes 100-999/1000` 的总长（1000）；拿不到返回 null。
///
/// 注意是**第三段**（`/` 后面那个），不是第二段的结束偏移；总长写成 `*` 时也返回 null。
int? contentRangeTotal(String? contentRange) {
  final m = _contentRange.firstMatch(contentRange?.trim() ?? '');
  if (m == null) return null;
  final total = m.group(3);
  if (total == null || total == '*') return null;
  return int.tryParse(total);
}

/// 这次响应该从哪个字节开始写：
///  * 0 —— 从头重写（没有半截文件 / 服务端没回 206 / 起点不是我们要的那个）；
///  * [existing] —— 接着 [existing] 后面追加。
int resumeWriteOffset({
  required int existing,
  required int status,
  String? contentRange,
}) {
  if (existing <= 0) return 0;
  if (status != 206) return 0;
  if (contentRangeStart(contentRange) != existing) return 0;
  return existing;
}

/// `bytes <start>-<end>/<total>`；end/total 可能是 `*`（部分服务器），
/// 所以只强取数字段。
final RegExp _contentRange = RegExp(r'^bytes\s+(\d+)-(\d+)\s*/\s*(\d+|\*)');
