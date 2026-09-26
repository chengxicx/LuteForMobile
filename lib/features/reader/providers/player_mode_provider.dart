import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// 朗读/音乐继续、句子高亮跟随照旧。会话级状态，不持久化。
class PlayerCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setCollapsed(bool collapsed) => state = collapsed;

  void toggle() => state = !state;
}

final playerCollapsedProvider = NotifierProvider<PlayerCollapsedNotifier, bool>(
  () => PlayerCollapsedNotifier(),
);
