/// "刚发出的 seek 到底落地了没有" —— 纯判定，没有插件、没有 IO，可以直接测。
///
/// 为什么需要它：用户按播放条左边的"上一句/下一句"、循环/自动暂停把播放头
/// 拽回句首、拖进度条，走的都是 `_audioPlayer.seek()`。**远程音源**（有声书
/// 的 `/useraudio/stream/<id>`）的 seekTo 要重新拉一段 HTTP Range 才生效，
/// 耗时秒级且不确定；在这段时间里 `onPositionChanged` 推来的还是**旧位置**。
///
/// 旧实现只用一个固定 600ms 的 `_boundaryHandledAt` 挡回声，窗口一过，在途的
/// 旧位置事件就被当成真实前进：既把 `state.position` 推回旧句（显示跳回去），
/// 又让"上一个位置"退到旧句，下一个事件看起来就跨过了句尾 —— 循环/自动暂停
/// 据此把播放头拽回旧句。用户看到的就是"按一下下一句没切过去"
/// （2026-10-10 手机实测：54:19 → 54:23 又被拉回 54:19）。
///
/// 所以判定标准从"过了 N 毫秒"换成"播放器报出的位置**真的到达目标**"。
library;

/// seek 落地（或放弃等待）到目标位置的容差。播放器报的位置与 seek 目标常有
/// 几十毫秒的取整差，卡太死会一直等不到"落地"。
const Duration kSeekTolerance = Duration(milliseconds: 400);

/// seek 迟迟没落地（远程音源被掐、seek 失败）时放弃等待的上限。
/// 不设上限会把播放条永久冻在目标位置上。
const Duration kSeekPendingTimeout = Duration(seconds: 12);

enum PendingSeekVerdict {
  /// 照常处理这条位置事件：没有在途的 seek，或者 seek 已经落地。
  proceed,

  /// 在途的 seek 还没落地 —— 这条事件是旧位置的迟到回声，整条丢弃。
  pending,

  /// 等太久了，放弃等待 —— 照常处理，并清掉在途状态。
  expired,
}

/// 跨过一个句尾边界时，播放头该往哪儿走。
enum SegmentBoundaryAction {
  /// 循环关、自动暂停关 —— 接着往下播，**不下发 seek**。
  ///
  /// 这一条是"记在途 seek"的禁区。没有真的 seek，却把句首（在播放头
  /// **后面**）记成在途目标的话，[seekHasLanded] 对往回跳要求
  /// `position <= target + 容差`，于是每条位置事件都被判成"还没落地"丢掉，
  /// 播放条会冻在跨界那一刻，直到 [kSeekPendingTimeout] 超时才放行。
  keepPlaying,

  /// 循环：跳回句首继续播。
  loopBack,

  /// 自动暂停：跳回句首并停住。
  pauseBack,
}

/// 句尾边界被跨越时该做什么。循环优先于自动暂停（与 web 播放器一致）。
///
/// 调用方必须按返回值决定要不要记在途 seek：[keepPlaying] 时**不能**记。
SegmentBoundaryAction segmentBoundaryAction({
  required bool loopMode,
  required bool autoPauseMode,
}) {
  if (loopMode) return SegmentBoundaryAction.loopBack;
  if (autoPauseMode) return SegmentBoundaryAction.pauseBack;
  return SegmentBoundaryAction.keepPlaying;
}

/// 播放器报出的 [position] 是不是已经到达 [target]（从 [origin] 出发）。
///
/// 方向按 `target > origin` 判：往前走就要求 `position >= target - 容差`，
/// 往回走就要求 `position <= target + 容差`。方向判错的话，往回跳会被
/// "起点本来就比目标大"直接判成落地，迟到的旧位置又会被放进来。
bool seekHasLanded({
  required Duration position,
  required Duration target,
  required Duration origin,
  Duration tolerance = kSeekTolerance,
}) {
  if (target > origin) return position >= target - tolerance;
  return position <= target + tolerance;
}

/// 位置事件到达时，在途 seek 该怎么处理。
///
/// 先判落地再判超时：远程音源的大跨度 seek 慢到超过 [timeout] 但**确实成功**
/// 的情况，按落地收尾才对（还能顺带补一次回声屏蔽）；反过来先判超时的话，
/// 一次成功的慢 seek 会被记成"放弃等待"。
PendingSeekVerdict evaluatePendingSeek({
  required Duration position,
  required Duration target,
  required Duration origin,
  required Duration elapsed,
  Duration tolerance = kSeekTolerance,
  Duration timeout = kSeekPendingTimeout,
}) {
  if (seekHasLanded(
    position: position,
    target: target,
    origin: origin,
    tolerance: tolerance,
  )) {
    return PendingSeekVerdict.proceed;
  }
  if (elapsed > timeout) return PendingSeekVerdict.expired;
  return PendingSeekVerdict.pending;
}
