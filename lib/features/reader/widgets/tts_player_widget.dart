import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/player_mode_provider.dart';
import '../providers/tts_player_provider.dart';
import 'player/player_card.dart';
import 'player/player_controls.dart';
import 'player/player_timeline.dart';

/// Full TTS read-aloud player bar (timeline + controls) for text books.
///
/// Mirrors the web reader's TTS player and reuses the same card components as
/// the MP3 [AudioPlayerWidget].  It reads the page's sentences sequentially
/// via the configured TTS service.
///
/// The aux row carries the − / + rate control (tap the number to reset), the
/// Loop / Auto-pause toggles, and — for books that have uploaded audio — the
/// switch back to the MP3 player.  Loop repeats the sentence being read;
/// auto-pause stops at the end of each one.  Loop wins when both are on.
class TTSPlayerWidget extends ConsumerStatefulWidget {
  /// 带音频的书才显示"切回 MP3"的按钮(纯文本书没有 MP3 可切)。
  final bool showMp3Toggle;

  const TTSPlayerWidget({super.key, this.showMp3Toggle = false});

  @override
  ConsumerState<TTSPlayerWidget> createState() => _TTSPlayerWidgetState();
}

class _TTSPlayerWidgetState extends ConsumerState<TTSPlayerWidget> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ttsPlayerProvider);
    final notifier = ref.read(ttsPlayerProvider.notifier);

    final sentenceLabel = state.hasSnippets
        ? '${state.currentIndex.clamp(0, state.snippets.length - 1) + 1}/${state.snippets.length}'
        : '0/0';

    final errorMessage = state.errorMessage;

    return PlayerCard(
      errorMessage: errorMessage == null ? null : 'Error: $errorMessage',
      onDismissError: errorMessage == null
          ? null
          : notifier.clearError,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerTimeline(
            position: state.position,
            total: state.totalDuration,
            centerLabel: sentenceLabel,
            onSeekEnd: (target) {
              final index = _indexForPosition(target, state);
              if (index >= 0) notifier.seekTo(index);
            },
          ),
          _buildMainControls(context, state),
          _buildAuxControls(context, state),
        ],
      ),
    );
  }

  Widget _buildMainControls(BuildContext context, TTSPlayerState state) {
    final notifier = ref.read(ttsPlayerProvider.notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        PlayerIconButton(
          icon: Icons.navigate_before,
          tooltip: 'Previous sentence',
          onPressed: state.canGoPrevious ? notifier.previous : null,
        ),
        const SizedBox(width: 8),
        PlayerPlayButton(
          playing: state.isPlaying,
          loading: state.isLoading,
          onPressed: () =>
              state.isPlaying ? notifier.pause() : notifier.toggle(),
        ),
        const SizedBox(width: 8),
        PlayerIconButton(
          icon: Icons.navigate_next,
          tooltip: 'Next sentence',
          onPressed: state.canGoNext ? notifier.next : null,
        ),
      ],
    );
  }

  Widget _buildAuxControls(BuildContext context, TTSPlayerState state) {
    final notifier = ref.read(ttsPlayerProvider.notifier);

    // FittedBox:窄屏上整行等比缩小,不裁切也不换行。
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerRateStepper(
            label: _formatRate(state.playbackRate),
            onDecrease: () =>
                notifier.nudgePlaybackRate(-TTSPlayerNotifier.playbackRateStep),
            onIncrease: () =>
                notifier.nudgePlaybackRate(TTSPlayerNotifier.playbackRateStep),
            onReset: notifier.resetPlaybackRate,
          ),
          PlayerIconButton(
            icon: state.loopMode ? Icons.repeat_on : Icons.repeat,
            active: state.loopMode,
            tooltip: state.loopMode
                ? 'Loop current sentence: on'
                : 'Loop current sentence: off',
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
          if (widget.showMp3Toggle)
            PlayerIconButton(
              icon: Icons.music_note,
              tooltip: 'Switch to MP3 audio',
              onPressed: () => ref
                  .read(playerModeProvider.notifier)
                  .setMode(PlayerMode.mp3),
            ),
        ],
      ),
    );
  }

  String _formatRate(double rate) {
    final text = rate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
    return '${text.isEmpty ? '1' : text}x';
  }

  /// Maps an overall timeline position back to the sentence index that it
  /// falls within.
  int _indexForPosition(Duration position, TTSPlayerState state) {
    var acc = Duration.zero;
    for (var i = 0; i < state.snippets.length; i++) {
      final next = acc + state.snippets[i].estimatedDuration;
      if (position < next || i == state.snippets.length - 1) {
        return i;
      }
      acc = next;
    }
    return state.snippets.isEmpty ? -1 : state.snippets.length - 1;
  }
}
