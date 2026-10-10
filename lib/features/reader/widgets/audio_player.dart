import 'package:audioplayers/audioplayers.dart' hide PlayerMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/models/tts_settings.dart';
import '../../settings/providers/tts_settings_provider.dart';
import '../providers/audio_player_provider.dart';
import '../providers/player_mode_provider.dart';
import 'player/player_card.dart';
import 'player/player_controls.dart';
import 'player/player_timeline.dart';

/// 有声书(MP3)的卡片式播放条。
///
/// 布局:时间行(两端对齐)+ 时间轴 / 主控行(上一句、播放、下一句)/
/// 辅助行(倍速、循环、自动暂停、AB 复读、影子跟读、TTS 切换)。
/// 主控行与辅助行的槽位顺序与 TTS 播放条**完全一致** —— 辅助行由
/// [PlayerAuxRow] 统一排布,两个播放器里同一个功能永远在同一个位置。
class AudioPlayerWidget extends ConsumerStatefulWidget {
  final String audioUrl;
  final int bookId;
  final int page;

  /// 用户书签（服务端同步）。只用于书签写回与时间轴刻度。
  final List<double>? bookmarks;

  /// 句子分段边界（SRT cue 起点；无 cues 的老书签书回退为书签）。
  /// 驱动循环/自动暂停的逐句判定与左右键切句；不参与书签写回、不画刻度。
  final List<double>? segmentBoundaries;
  final Duration? audioCurrentPos;

  /// 影子跟读入口:对"当前播放句"录音打分。null 时不画该键(无句子的
  /// 页面,如漫画/PDF)。
  final VoidCallback? onShadowing;

  const AudioPlayerWidget({
    super.key,
    required this.audioUrl,
    required this.bookId,
    required this.page,
    this.bookmarks,
    this.segmentBoundaries,
    this.audioCurrentPos,
    this.onShadowing,
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
    final segmentSignature = (widget.segmentBoundaries ?? const [])
        .map((boundary) => boundary.toStringAsFixed(3))
        .join(',');
    final currentPosSeconds =
        widget.audioCurrentPos?.inMilliseconds.toString() ?? 'null';
    final loadSignature =
        '${widget.audioUrl}|${widget.bookId}|${widget.page}|$currentPosSeconds|'
        '$bookmarkSignature|$segmentSignature';

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
            segmentBoundaries: widget.segmentBoundaries,
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
            abStart: audioPlayerState.abPhase != AbLoopPhase.off
                ? audioPlayerState.abStart
                : null,
            abEnd: audioPlayerState.abPhase == AbLoopPhase.looping
                ? audioPlayerState.abEnd
                : null,
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
          icon: Icons.navigate_before,
          tooltip: 'Previous sentence',
          onPressed: notifier.goToPreviousSegment,
        ),
        const SizedBox(width: 8),
        PlayerPlayButton(
          playing: playing,
          onPressed: () => playing ? notifier.pause() : notifier.play(),
        ),
        const SizedBox(width: 8),
        PlayerIconButton(
          icon: Icons.navigate_next,
          tooltip: 'Next sentence',
          onPressed: notifier.goToNextSegment,
        ),
      ],
    );
  }

  Widget _buildAuxControls(
    BuildContext context,
    AudioPlayerState state,
    TTSProvider ttsProvider,
  ) {
    final notifier = ref.read(audioPlayerProvider.notifier);

    // 槽位顺序由 PlayerAuxRow 固定，与 TTS 播放条完全一致：
    // 倍速 → 循环 → 自动暂停 → AB → 跟读 → 切换播放器。
    return PlayerAuxRow(
      rate: PlayerRateStepper(
        label: formatPlayerRate(state.playbackSpeed),
        onDecrease: () => _stepSpeed(-1),
        onIncrease: () => _stepSpeed(1),
        onReset: () => notifier.setPlaybackSpeed(1.0),
      ),
      // 循环用 loop 图标，与 AB 键的 repeat 系区分（两个 repeat 并排难分辨）；
      // 图标不随开关变（换图标是 TTS 条原先的做法），开没开由 active 的
      // 实心圆底表达，两条播放条同一套。
      loop: PlayerIconButton(
        icon: Icons.loop,
        active: state.loopMode,
        tooltip: state.loopMode ? 'Loop sentence on' : 'Loop sentence off',
        onPressed: notifier.toggleLoopMode,
      ),
      autoPause: PlayerIconButton(
        icon: state.autoPauseMode
            ? Icons.pause_circle
            : Icons.pause_circle_outline,
        active: state.autoPauseMode,
        tooltip: state.autoPauseMode
            ? 'Auto-pause at each sentence: on'
            : 'Auto-pause at each sentence: off',
        onPressed: notifier.toggleAutoPauseMode,
      ),
      // AB 复读：文字三态，一眼可辨 ——
      // 熄灭 "AB"(无底) → 标 A "A"(点亮实心圆) → 循环中 "AB"(点亮实心圆)。
      ab: PlayerIconButton(
        label: state.abPhase == AbLoopPhase.aMarked ? 'A' : 'AB',
        active: state.abPhase != AbLoopPhase.off,
        tooltip: switch (state.abPhase) {
          AbLoopPhase.off => 'AB repeat: tap to mark A',
          AbLoopPhase.aMarked => 'AB repeat: A marked, tap to mark B',
          AbLoopPhase.looping => 'AB repeat on: tap to cancel',
        },
        onPressed: notifier.toggleAbLoop,
      ),
      shadowing: widget.onShadowing == null
          ? null
          : PlayerIconButton(
              icon: Icons.mic,
              tooltip: 'Shadowing: record yourself reading this sentence',
              onPressed: widget.onShadowing,
            ),
      // 恒渲染;TTS 引擎没配置时置灰禁用,保持与 TTS 条结构一致。
      modeSwitch: PlayerIconButton(
        icon: Icons.record_voice_over,
        tooltip: ttsProvider == TTSProvider.none
            ? 'TTS read-aloud is not configured'
            : 'Switch to TTS read-aloud',
        onPressed: ttsProvider == TTSProvider.none
            ? null
            : () => ref
                  .read(playerModeProvider.notifier)
                  .setMode(PlayerMode.tts),
        slashWhenDisabled: true,
      ),
    );
  }

  void _stepSpeed(int direction) {
    final current = ref.read(audioPlayerProvider).playbackSpeed;
    var index = _speeds.indexOf(current);
    if (index < 0) index = _speeds.indexOf(1.0);
    final nextIndex = (index + direction).clamp(0, _speeds.length - 1);
    ref.read(audioPlayerProvider.notifier).setPlaybackSpeed(_speeds[nextIndex]);
  }
}
