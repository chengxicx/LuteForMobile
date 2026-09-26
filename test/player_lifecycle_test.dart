// 阅读页「app 生命周期 → 是否停 MP3」的契约测试。
//
// 起因（2026-09-26 Leaf 5C 实测）：MP3 播放中按实体音量键，播放停止且进度归零。
// 根因不是音量键本身 —— 音量面板弹出让 Flutter 窗口失焦 →
// AppLifecycleState.inactive → 阅读页把播放器 reset() 了（停止 + 进度清空）。
// 下拉控制中心（通知栏）能复现同一现象，证明触发条件是「窗口失焦」而非按键。
//
// 这里钉住两件事：
//   1. inactive **不**停播放 —— 音量面板 / 控制中心 / 权限弹窗 / 分屏都会
//      触发它，此时用户还在看书、还在听；
//   2. paused 仍然停播放 —— 真正切后台不能漏掉。
//
// 运行：flutter test test/player_lifecycle_test.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/player_lifecycle.dart';

void main() {
  group('shouldStopAudioOnLifecycleChange', () {
    test('inactive 不停播放（窗口失焦：音量面板 / 控制中心 / 权限弹窗）', () {
      expect(
        shouldStopAudioOnLifecycleChange(AppLifecycleState.inactive),
        isFalse,
        reason: 'inactive 只是窗口失焦，用户还在看书、还在听，停掉并清空进度是 bug',
      );
    });

    test('paused 停播放（真正切后台）', () {
      expect(
        shouldStopAudioOnLifecycleChange(AppLifecycleState.paused),
        isTrue,
        reason: '切后台的序列是 inactive → hidden → paused，paused 必须兜住',
      );
    });

    test('resumed / hidden / detached 不在本判定里停播放', () {
      expect(
        shouldStopAudioOnLifecycleChange(AppLifecycleState.resumed),
        isFalse,
      );
      expect(
        shouldStopAudioOnLifecycleChange(AppLifecycleState.hidden),
        isFalse,
        reason: 'hidden 只是过渡态，紧随其后的 paused 才是「离开 app」',
      );
      expect(
        shouldStopAudioOnLifecycleChange(AppLifecycleState.detached),
        isFalse,
      );
    });
  });
}
