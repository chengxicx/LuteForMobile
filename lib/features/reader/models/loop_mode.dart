/// 播放条"循环"键的三态。
///
/// 点一下走一格：单句循环 → 整段循环 → 关。两条播放条共用同一套档位与
/// 同一个键位（见 `PlayerAuxRow`），差别只在"整段"指什么：
///  * MP3 条：[all] 是**这一首音频**，播完回到 0s 继续（单曲循环）；
///  * TTS 条：[all] 是**这本书**，读完本页自动翻页接着念，书末回到第 1 页。
///
/// 之所以不是 `bool`：两态下"整曲/整本循环"根本没有位置。而循环按钮的
/// 语义又必须一眼可辨 —— [sentence] 与 [all] 都点亮，靠图标区分（带 1 的
/// `repeat_one` = 单句，无 1 的 `loop` = 整段），灰阶墨水屏上靠形状而不是
/// 深浅分辨。
enum LoopMode {
  off,
  sentence,
  all;

  /// 循环是否开着（[sentence] 与 [all] 都算）。循环开着时自动暂停被压制，
  /// 见各播放器的 `_onServiceCompleted` / `segmentBoundaryAction`。
  bool get isOn => this != LoopMode.off;

  /// 下一档：off → sentence → all → off。
  LoopMode get next => switch (this) {
    LoopMode.off => LoopMode.sentence,
    LoopMode.sentence => LoopMode.all,
    LoopMode.all => LoopMode.off,
  };
}
