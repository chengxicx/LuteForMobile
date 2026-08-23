import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/tts_player_provider.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Full TTS read-aloud player bar (timeline + controls) for text books.
///
/// Mirrors the web reader's TTS player and reuses the same visual language as
/// the MP3 [AudioPlayerWidget]: a timeline slider over the whole page plus
/// previous / play-pause / next controls.  It reads the page's sentences
/// sequentially via the configured TTS service.
class TTSPlayerWidget extends ConsumerStatefulWidget {
  const TTSPlayerWidget({super.key});

  @override
  ConsumerState<TTSPlayerWidget> createState() => _TTSPlayerWidgetState();
}

class _TTSPlayerWidgetState extends ConsumerState<TTSPlayerWidget> {
  bool _isDragging = false;
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ttsPlayerProvider);

    return Container(
      decoration: BoxDecoration(
        color: context.audioPlayerBackground,
        border: Border(
          bottom: BorderSide(
            color: context.appColorScheme.border.outline,
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 4.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.errorMessage != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(8.0),
              margin: EdgeInsets.only(bottom: 4.0),
              color: context.audioErrorBackground,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Error: ${state.errorMessage}',
                      style: TextStyle(color: context.audioError),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: context.audioError),
                    onPressed: () {
                      ref.read(ttsPlayerProvider.notifier).play();
                    },
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          _buildProgressBar(context, state),
          _buildControlRow(context, state),
        ],
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, TTSPlayerState state) {
    final totalSeconds = state.totalDuration.inMilliseconds / 1000.0;
    final positionSeconds = state.position.inMilliseconds / 1000.0;
    final maxDuration = totalSeconds > 0 ? totalSeconds : 1.0;

    double sliderValue = _isDragging ? (_dragSeconds ?? positionSeconds) : positionSeconds;
    if (sliderValue > maxDuration) sliderValue = maxDuration;

    final sentenceLabel = state.hasSnippets
        ? '${state.currentIndex.clamp(0, state.snippets.length - 1) + 1}/${state.snippets.length}'
        : '0/0';

    return Container(
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4.0,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.0),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 12.0),
            ),
            child: Slider(
              value: sliderValue,
              min: 0.0,
              max: maxDuration,
              onChanged: (value) {
                setState(() {
                  _isDragging = true;
                  _dragSeconds = value;
                });
              },
              onChangeEnd: (value) {
                final target = Duration(milliseconds: (value * 1000).round());
                final index = _indexForPosition(target, state);
                setState(() {
                  _isDragging = false;
                  _dragSeconds = null;
                });
                ref.read(ttsPlayerProvider.notifier).seekTo(index);
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Text(
                  '${_formatDuration(state.position)} / ${_formatDuration(state.totalDuration)} · $sentenceLabel',
                  style: TextStyle(
                    color: context.audioPlayerIcon,
                    fontSize: 12,
                    shadows: [
                      Shadow(
                        blurRadius: 3.0,
                        color: context.appColorScheme.text.disabled.withValues(
                          alpha: 0.7,
                        ),
                        offset: Offset(0, 0),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlRow(BuildContext context, TTSPlayerState state) {
    final notifier = ref.read(ttsPlayerProvider.notifier);

    IconData playPauseIcon;
    VoidCallback playPauseAction;
    if (state.isLoading) {
      playPauseIcon = Icons.hourglass_empty;
      playPauseAction = () {};
    } else if (state.isPlaying) {
      playPauseIcon = Icons.pause;
      playPauseAction = () => notifier.pause();
    } else {
      playPauseIcon = Icons.play_arrow;
      playPauseAction = () => notifier.toggle();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(Icons.navigate_before),
            onPressed: state.canGoPrevious
                ? () => notifier.previous()
                : null,
            color: context.audioPlayerIcon,
            iconSize: 22,
            padding: EdgeInsets.all(4),
            tooltip: 'Previous sentence',
          ),
          IconButton(
            icon: Icon(playPauseIcon),
            onPressed: playPauseAction,
            color: context.audioPlayerIcon,
            iconSize: 32,
          ),
          IconButton(
            icon: Icon(Icons.navigate_next),
            onPressed: state.canGoNext ? () => notifier.next() : null,
            color: context.audioPlayerIcon,
            iconSize: 22,
            padding: EdgeInsets.all(4),
            tooltip: 'Next sentence',
          ),
        ],
      ),
    );
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

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}