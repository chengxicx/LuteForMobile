import 'package:audioplayers/audioplayers.dart' hide PlayerMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/player_palette.dart';
import '../../settings/models/tts_settings.dart';
import '../../settings/providers/tts_settings_provider.dart';
import '../providers/audio_player_provider.dart';
import '../providers/player_mode_provider.dart';
import 'player/player_card.dart';
import 'player/player_controls.dart';
import 'player/player_timeline.dart';

/// 有声书(MP3)的卡片式播放条。
///
/// 布局:时间行(两端对齐)+ 时间轴 / 主控行(±10s 与大播放键)/
/// 辅助行(书签组、循环、自动暂停、倍速、TTS 切换)。
class AudioPlayerWidget extends ConsumerStatefulWidget {
  final String audioUrl;
  final int bookId;
  final int page;
  final List<double>? bookmarks;
  final Duration? audioCurrentPos;

  const AudioPlayerWidget({
    super.key,
    required this.audioUrl,
    required this.bookId,
    required this.page,
    this.bookmarks,
    this.audioCurrentPos,
  });

  @override
  ConsumerState<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends ConsumerState<AudioPlayerWidget> {
  String? _lastLoadSignature;
  static const List<double> _speeds = [
    0.6,
    0.7,
    0.8,
    0.9,
    1.0,
    1.1,
    1.2,
    1.3,
    1.4,
    1.5,
  ];

  @override
  Widget build(BuildContext context) {
    final audioPlayerState = ref.watch(audioPlayerProvider);
    final ttsProvider = ref.watch(
      ttsSettingsProvider.select((s) => s.provider),
    );
    final bookmarkSignature = (widget.bookmarks ?? const [])
        .map((bookmark) => bookmark.toStringAsFixed(3))
        .join(',');
    final currentPosSeconds =
        widget.audioCurrentPos?.inMilliseconds.toString() ?? 'null';
    final loadSignature =
        '${widget.audioUrl}|${widget.bookId}|${widget.page}|$currentPosSeconds|$bookmarkSignature';

    // Reload when the server-provided audio state changes, not only the URL.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_lastLoadSignature != loadSignature && !audioPlayerState.isLoading) {
        _lastLoadSignature = loadSignature;
        final notifier = ref.read(audioPlayerProvider.notifier);
        // 播放条因 MP3⇄TTS 模式切换重新挂载时音源还在,签名没变就不重载,
        // 保住切换前的播放位置。
        if (notifier.lastLoadSignature != loadSignature) {
          notifier.loadAudio(
            audioUrl: widget.audioUrl,
            bookId: widget.bookId,
            page: widget.page,
            bookmarks: widget.bookmarks,
            audioCurrentPos: widget.audioCurrentPos,
          );
        }
      }
    });

    final errorMessage = audioPlayerState.errorMessage;

    return PlayerCard(
      errorMessage: errorMessage == null ? null : 'Error: $errorMessage',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerTimeline(
            position: audioPlayerState.position,
            total: audioPlayerState.duration,
            bookmarks: audioPlayerState.bookmarkDurations,
            onSeekEnd: (position) =>
                ref.read(audioPlayerProvider.notifier).seek(position),
          ),
          _buildMainControls(context, audioPlayerState),
          _buildAuxControls(context, audioPlayerState, ttsProvider),
        ],
      ),
    );
  }

  Widget _buildMainControls(BuildContext context, AudioPlayerState state) {
    final playing = state.playerState == PlayerState.playing;
    final notifier = ref.read(audioPlayerProvider.notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        PlayerIconButton(
          icon: Icons.replay_10,
          large: true,
          tooltip: 'Back 10 seconds',
          onPressed: () => _seekBy(state, const Duration(seconds: -10)),
        ),
        const SizedBox(width: 8),
        PlayerPlayButton(
          playing: playing,
          onPressed: () => playing ? notifier.pause() : notifier.play(),
        ),
        const SizedBox(width: 8),
        PlayerIconButton(
          icon: Icons.forward_10,
          large: true,
          tooltip: 'Forward 10 seconds',
          onPressed: () => _seekBy(state, const Duration(seconds: 10)),
        ),
      ],
    );
  }

  Widget _buildAuxControls(
    BuildContext context,
    AudioPlayerState state,
    TTSProvider ttsProvider,
  ) {
    final palette = context.playerPalette;
    final notifier = ref.read(audioPlayerProvider.notifier);
    final isAtBookmark = notifier.isAtBookmark();

    // FittedBox:窄屏(小屏/分屏)上整行等比缩小,不裁切也不换行。
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: palette.groupFill,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlayerIconButton(
                  icon: Icons.navigate_before,
                  tooltip: 'Previous bookmark',
                  onPressed: notifier.goToPreviousBookmark,
                ),
                PlayerIconButton(
                  icon: isAtBookmark ? Icons.bookmark : Icons.bookmark_border,
                  active: isAtBookmark,
                  tooltip: isAtBookmark ? 'Remove bookmark' : 'Add bookmark',
                  onPressed: () {
                    if (isAtBookmark) {
                      notifier.removeBookmark();
                    } else {
                      notifier.addBookmark();
                    }
                  },
                ),
                PlayerIconButton(
                  icon: Icons.navigate_next,
                  tooltip: 'Next bookmark',
                  onPressed: notifier.goToNextBookmark,
                ),
              ],
            ),
          ),
          PlayerIconButton(
            icon: state.loopMode ? Icons.repeat_on : Icons.repeat,
            active: state.loopMode,
            tooltip: state.loopMode ? 'Loop sentence on' : 'Loop sentence off',
            onPressed: notifier.toggleLoopMode,
          ),
          PlayerIconButton(
            icon: state.autoPauseMode
                ? Icons.pause_circle
                : Icons.pause_circle_outline,
            active: state.autoPauseMode,
            tooltip: state.autoPauseMode
                ? 'Auto-pause at each sentence: on'
                : 'Auto-pause at each sentence: off',
            onPressed: notifier.toggleAutoPauseMode,
          ),
          PlayerRateStepper(
            label: '${state.playbackSpeed.toStringAsFixed(1)}x',
            onDecrease: () => _stepSpeed(-1),
            onIncrease: () => _stepSpeed(1),
            onReset: () => notifier.setPlaybackSpeed(1.0),
          ),
          if (ttsProvider != TTSProvider.none)
            PlayerIconButton(
              icon: Icons.record_voice_over,
              tooltip: 'Switch to TTS read-aloud',
              onPressed: () => ref
                  .read(playerModeProvider.notifier)
                  .setMode(PlayerMode.tts),
            ),
        ],
      ),
    );
  }

  void _seekBy(AudioPlayerState state, Duration offset) {
    final target = state.position + offset;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > state.duration && state.duration > Duration.zero
              ? state.duration
              : target);
    ref.read(audioPlayerProvider.notifier).seek(clamped);
  }

  void _stepSpeed(int direction) {
    final current = ref.read(audioPlayerProvider).playbackSpeed;
    var index = _speeds.indexOf(current);
    if (index < 0) index = _speeds.indexOf(1.0);
    final nextIndex = (index + direction).clamp(0, _speeds.length - 1);
    ref.read(audioPlayerProvider.notifier).setPlaybackSpeed(_speeds[nextIndex]);
  }
}
