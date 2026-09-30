import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_settings/app_settings.dart';

import '../../../shared/theme/player_palette.dart';
import '../../reader/providers/sentence_tts_provider.dart';
import '../../reader/widgets/player/player_controls.dart';
import '../models/shadowing_result.dart';
import '../models/shadowing_sentence.dart';
import '../providers/shadowing_provider.dart';

/// The shadowing panel: pick a sentence, listen to the reference, record
/// yourself reading it, see the score.
///
/// A bottom sheet rather than an inline pane (the web reader docks into the
/// right column) -- the reader screen has no right column to dock into, and
/// the take is a modal "listen -> speak -> look" loop anyway.
class ShadowingSheet extends ConsumerStatefulWidget {
  final List<ShadowingSentence> sentences;
  final int initialIndex;

  const ShadowingSheet({
    super.key,
    required this.sentences,
    required this.initialIndex,
  });

  @override
  ConsumerState<ShadowingSheet> createState() => _ShadowingSheetState();
}

class _ShadowingSheetState extends ConsumerState<ShadowingSheet> {
  late int _currentIndex = widget.initialIndex.clamp(
    0,
    widget.sentences.isEmpty ? 0 : widget.sentences.length - 1,
  );

  ShadowingSentence get _sentence =>
      widget.sentences[_currentIndex.clamp(0, widget.sentences.length - 1)];

  void _moveSentence(int delta) {
    final next = (_currentIndex + delta).clamp(0, widget.sentences.length - 1);
    if (next == _currentIndex) return;
    // 新句子从零开始:上一句的 take、结果、回放都属于上一句。
    ref.read(shadowingProvider.notifier).reset();
    setState(() => _currentIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(shadowingProvider);
    final palette = context.playerPalette;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: palette.card,
        border: Border.fromBorderSide(
          BorderSide(
            color: palette.cardBorder,
            width: palette.cardBorderWidth,
          ),
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, palette),
              const SizedBox(height: 8),
              _buildSentenceText(palette),
              const SizedBox(height: 12),
              _buildControls(context, state, palette),
              if (state.isRecording || state.isProcessing)
                _buildStatusLine(state, palette),
              _buildErrorBlock(context, state, palette),
              if (state.hasResult) ...[
                const SizedBox(height: 12),
                _buildResult(context, state, palette),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, PlayerPalette palette) {
    final ttsState = ref.watch(sentenceTTSProvider);
    return Row(
      children: [
        Text(
          'Shadowing',
          style: TextStyle(
            color: palette.icon,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        PlayerIconButton(
          icon: Icons.navigate_before,
          tooltip: 'Previous sentence',
          onPressed: _currentIndex > 0 ? () => _moveSentence(-1) : null,
        ),
        Text(
          '${_currentIndex + 1}/${widget.sentences.length}',
          style: TextStyle(
            color: palette.muted,
            fontSize: palette.labelFontSize + 1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        PlayerIconButton(
          icon: Icons.navigate_next,
          tooltip: 'Next sentence',
          onPressed: _currentIndex < widget.sentences.length - 1
              ? () => _moveSentence(1)
              : null,
        ),
        // TTS 参考在播时给个停口:它不在 shadowingProvider 的控制里,
        // 关面板时才被顺带停掉,面板开着时用户要能手动停。
        if (ttsState.isPlaying)
          PlayerIconButton(
            icon: Icons.stop,
            tooltip: 'Stop the TTS reading',
            onPressed: () =>
                ref.read(sentenceTTSProvider.notifier).stop(),
          ),
        PlayerIconButton(
          icon: Icons.close,
          tooltip: 'Close shadowing',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildSentenceText(PlayerPalette palette) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.groupFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _sentence.displayText,
        style: TextStyle(
          color: palette.icon,
          fontSize: 19,
          height: 1.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    ShadowingState state,
    PlayerPalette palette,
  ) {
    final notifier = ref.read(shadowingProvider.notifier);
    final ttsState = ref.watch(sentenceTTSProvider);
    final referenceActive = state.playingReference || ttsState.isPlaying;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PlayerIconButton(
              icon: state.playingReference
                  ? Icons.stop
                  : Icons.volume_up,
              active: state.playingReference,
              tooltip: _referenceTooltip(state),
              onPressed: referenceActive && state.playingReference
                  ? notifier.stopReference
                  : () => notifier.playReference(_sentence),
            ),
            const SizedBox(width: 16),
            _buildRecordButton(context, state, palette, notifier),
            const SizedBox(width: 16),
            // 有 take 才能回放;录音中/上传中按钮熄着。
            PlayerIconButton(
              icon: state.playingRecording
                  ? Icons.stop
                  : Icons.play_circle,
              active: state.playingRecording,
              tooltip: state.playingRecording
                  ? 'Stop your recording'
                  : 'Play your recording',
              onPressed: state.hasTake
                  ? () => state.playingRecording
                        ? notifier.stopRecordingPlayback()
                        : notifier.playRecording()
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 4),
        _buildModelSelector(palette, notifier),
      ],
    );
  }

  String _referenceTooltip(ShadowingState state) {
    if (state.playingReference) return 'Stop the reference';
    return _sentence.hasClip
        ? 'Play the sentence from the song'
        : 'Read the sentence aloud (TTS)';
  }

  /// 录音主键:与播放条的主播放键同一视觉层级(大圆底),录音中变停止键。
  Widget _buildRecordButton(
    BuildContext context,
    ShadowingState state,
    PlayerPalette palette,
    ShadowingNotifier notifier,
  ) {
    final recording = state.isRecording;
    final processing = state.isProcessing;
    return GestureDetector(
      onTap: processing ? null : () => notifier.toggleRecording(_sentence),
      child: Container(
        width: palette.playButtonSize,
        height: palette.playButtonSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: recording ? palette.errorInk : palette.playSurface,
        ),
        child: Icon(
          recording ? Icons.stop : Icons.mic,
          size: palette.playIconSize,
          color: recording ? palette.playInk : palette.icon,
        ),
      ),
    );
  }

  Widget _buildModelSelector(
    PlayerPalette palette,
    ShadowingNotifier notifier,
  ) {
    // Only sizes already downloaded on the server, once at least one is
    // cached -- a dropdown tap must not silently start a multi-hundred-MB
    // download server-side.  Nothing cached yet (or the server could not
    // be asked): every size stays offered, the first download is
    // unavoidable anyway.
    final state = ref.watch(shadowingProvider);
    final offered = state.cachedModels ?? kShadowingModelSizes;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Whisper model',
          style: TextStyle(color: palette.muted, fontSize: 12),
        ),
        const SizedBox(width: 6),
        DropdownButton<String>(
          value: offered.contains(state.modelSize)
              ? state.modelSize
              : offered.first,
          underline: const SizedBox.shrink(),
          isDense: true,
          style: TextStyle(color: palette.icon, fontSize: 13),
          dropdownColor: palette.card,
          icon: Icon(Icons.arrow_drop_down, color: palette.muted, size: 20),
          items: offered
              .map(
                (size) => DropdownMenuItem(value: size, child: Text(size)),
              )
              .toList(),
          onChanged: (size) {
            if (size != null) notifier.setModelSize(size);
          },
        ),
      ],
    );
  }

  Widget _buildStatusLine(ShadowingState state, PlayerPalette palette) {
    final String text;
    if (state.isRecording) {
      text =
          'Recording… ${state.recordingSeconds}s/${ShadowingNotifier.maxRecordingSeconds}s -- read the sentence aloud';
    } else if (state.waitPhase == ShadowingWaitPhase.loadingModel) {
      // Only the first take of a session waits here (the model is cached
      // afterwards, per size) -- say so rather than blaming every slow
      // transcription on the model load.
      final hint = state.waitSeconds > 20
          ? ' (first run downloads it, this can take minutes)'
          : '';
      text = 'Loading the whisper model… ${state.waitSeconds}s$hint';
    } else {
      text = 'Transcribing… ${state.waitSeconds}s';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state.isProcessing)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.icon,
              ),
            )
          else
            Icon(Icons.fiber_manual_record, size: 12, color: palette.errorInk),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(color: palette.icon, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBlock(
    BuildContext context,
    ShadowingState state,
    PlayerPalette palette,
  ) {
    final error = state.error;
    if (error == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.errorBackground,
          border: Border.all(color: palette.errorInk),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error.message,
              style: TextStyle(color: palette.errorInk, fontSize: 13),
            ),
            if (error.kind == ShadowingErrorKind.permissionDenied)
              TextButton(
                onPressed: AppSettings.openAppSettings,
                child: const Text('Open app settings'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(
    BuildContext context,
    ShadowingState state,
    PlayerPalette palette,
  ) {
    final result = state.result!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${result.score}%',
              style: TextStyle(
                color: palette.icon,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                _rateLabel(result),
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildTokenChips(result, palette),
        if (result.extras.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Also heard: ${result.extras.join(', ')}',
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Heard: ${result.transcription.isEmpty ? '--' : result.transcription}',
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      ],
    );
  }

  String _rateLabel(ShadowingResult result) {
    final kind = result.tokenKind == 'morpheme' ? 'morphemes' : 'words';
    final rate = result.tokensPerMinute;
    final ratePart = rate == null ? '' : ' · ${rate.toStringAsFixed(1)} $kind/min';
    return '$kind read: ${result.matched} ok, ${result.fuzzy} off, '
        '${result.total - result.matched - result.fuzzy} missed'
        '$ratePart';
  }

  /// 逐词判词:绿 = 读对、琥珀 = 错读(附实际听到的)、红 = 漏读。
  /// 颜色之外每个状态还带一个符号前缀 —— 墨水屏把三色量化成灰阶后,
  /// 符号仍把状态区分开(与播放条 active 键"靠形状不靠色"同一个道理)。
  Widget _buildTokenChips(ShadowingResult result, PlayerPalette palette) {
    final tokens = _sentence.tokens;
    final children = <Widget>[];
    for (var i = 0; i < result.statuses.length && i < tokens.length; i++) {
      final status = result.statuses[i];
      final token = tokens[i];
      if (token.trim().isEmpty) continue;

      final (color, prefix, borderStyle) = switch (status) {
        ShadowingTokenStatus.match => (Colors.green.shade700, '✓ ', null),
        ShadowingTokenStatus.fuzzy => (Colors.orange.shade800, '~ ', BorderStyle.solid),
        ShadowingTokenStatus.miss => (Colors.red.shade700, '✗ ', BorderStyle.solid),
      };

      children.add(
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.fromBorderSide(
              BorderSide(
                color: status == ShadowingTokenStatus.match
                    ? Colors.transparent
                    : color,
                style: borderStyle ?? BorderStyle.none,
                width: 1.4,
              ),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            status == ShadowingTokenStatus.fuzzy
                ? '$prefix$token → ${result.spokenForFuzzy[i] ?? '?'}'
                : '$prefix$token',
            style: TextStyle(color: color, fontSize: 14, height: 1.3),
          ),
        ),
      );
    }
    return Wrap(children: children);
  }
}
