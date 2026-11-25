import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底部播放条的模式:听有声书(MP3)还是 TTS 朗读原文。
///
/// 只对带音频的书有意义 —— 纯文本书永远显示 TTS 朗读条。会话级状态,
/// 不持久化:每次进书默认 MP3(重置见 ReaderScreen._loadAudioIfNeeded)。
enum PlayerMode { mp3, tts }

class PlayerModeNotifier extends Notifier<PlayerMode> {
  @override
  PlayerMode build() => PlayerMode.mp3;

  void setMode(PlayerMode mode) {
    state = mode;
  }
}

final playerModeProvider =
    NotifierProvider<PlayerModeNotifier, PlayerMode>(
      () => PlayerModeNotifier(),
    );

/// 播放条是否被快捷按钮收起（AppBar 上的收起/恢复切换）。
///
/// 只影响播放条的可见性：播放状态都在各自的 provider 里，收起后
/// 朗读/音乐继续、句子高亮跟随照旧。
///
/// **会持久化**。原来是纯会话状态，于是「收起播放条 → 切到别的应用 → 回来
/// 它又滑出来」：进程被系统回收后重建、或当时恰好落在另一份任务/engine 上
/// （见 AndroidManifest 里 launchMode 的注释），`build()` 一律又给 false。
/// 收起是用户明确表达过的偏好，不该十秒后自己反悔。恢复入口没变 —— AppBar
/// 上那个按钮一直在（收起时显示当前模式的图标）。
class PlayerCollapsedNotifier extends Notifier<bool> {
  static const String _prefKey = 'reader_player_collapsed';

  @override
  bool build() {
    // 先给默认值，同时把上次的选择读回来；读到就改，读不到就保持展开，
    // 与从前的行为一致。
    unawaited(_restore());
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefKey);
      if (saved != null && saved != state) state = saved;
    } catch (_) {
      // 读不出来（存储不可用）只影响"记住"，本次按展开处理。
    }
  }

  void setCollapsed(bool collapsed) {
    state = collapsed;
    unawaited(_persist(collapsed));
  }

  void toggle() => setCollapsed(!state);

  Future<void> _persist(bool collapsed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, collapsed);
    } catch (_) {
      // 存不下去只影响下次启动，不影响这一次。
    }
  }
}

final playerCollapsedProvider = NotifierProvider<PlayerCollapsedNotifier, bool>(
  () => PlayerCollapsedNotifier(),
);
