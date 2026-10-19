import 'package:flutter/widgets.dart';

/// 阅读页遇到 app 生命周期变化时，是否该停掉 MP3 播放器。
///
/// **只有真正离开 app（`paused`）才停，刻意不含 `inactive`。**
///
/// Android 上窗口一失焦就是 `inactive`，而下面这些都会让窗口失焦：
/// 系统音量面板、控制中心/通知栏、权限弹窗、分屏拖动。这些场景里用户还在
/// 看书、还在听，此时 `reset()` 会停止播放**并把进度清空到 0**
/// （2026-09-26 Leaf 5C 反馈：播放中按音量键，播放停止且进度归零）。
///
/// 切后台的完整序列是 `inactive → hidden → paused`，所以去掉 `inactive`
/// 之后，真正离开 app 仍然会被 `paused` 兜住，不会漏。
///
/// [backgroundPlayback] 为 true 时**一律不停**：用户明确要求锁屏后继续
/// 有声书 / 整页朗读（2026-10-19）。那时靠 `MediaPlaybackService` 这个
/// mediaPlayback 类型的前台服务兜住进程，回来时的位置由播放器自己保持，
/// 不再走 `suspendForBackground` / `restoreAfterBackground` 那一套。
bool shouldStopAudioOnLifecycleChange(
  AppLifecycleState state, {
  bool backgroundPlayback = false,
}) {
  if (backgroundPlayback) return false;
  return state == AppLifecycleState.paused;
}
