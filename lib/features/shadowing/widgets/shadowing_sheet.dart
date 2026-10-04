import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_settings/app_settings.dart';

import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/player_palette.dart';
import '../../../shared/theme/theme_extensions.dart';
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

  /// 点词发音的两级反馈:按压瞬间(_pressed)与发音期间(_speaking)。
  /// 记录 (区域, 词序号):原句、结果 Heard 区和判定胶囊共用同一个状态,
  /// 光有序号会撞车(两区都有第 3 个词),所以带上区域名。
  (String, int)? _pressed;
  (String, int)? _speaking;

  /// 判定胶囊的「先读对的、再读错的」:第一段(正确读音)由
  /// _speakChip 直接开口;第二段(实际听到的错词)挂在
  /// _pendingChipSpoken 上,等句子 TTS 状态回到 idle/错误时由 build 里的
  /// ref.listen 接上 —— speakSentence 在开播后就返回,播完信号只有
  /// 状态回落,没有别的回调可用。
  String? _pendingChipSpoken;
  int? _pendingChipIndex;

  /// 出分后把结果滚进可视区用的。
  final GlobalKey _resultKey = GlobalKey();

  static const _areaSentence = 'sentence';
  static const _areaHeard = 'heard';
  static const _areaChip = 'chip';

  @override
  void initState() {
    super.initState();
    // 面板一开就取当前句的假名标注:原句在录音之前就要能显示 furigana。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(shadowingProvider.notifier).loadReadings(_sentence);
    });
  }

  void _moveSentence(int delta) {
    final next = (_currentIndex + delta).clamp(0, widget.sentences.length - 1);
    if (next == _currentIndex) return;
    // 新句子从零开始:上一句的 take、结果、回放都属于上一句。
    ref.read(shadowingProvider.notifier).reset();
    setState(() {
      _currentIndex = next;
      _pressed = null;
      _speaking = null;
      _pendingChipSpoken = null;
      _pendingChipIndex = null;
    });
    ref.read(shadowingProvider.notifier).loadReadings(_sentence);
  }

  /// 左右滑切换句子(左滑下一句、右滑上一句):翻句是"听→读→看分"循环里
  /// 最高频的动作,给一个不用瞄准按钮的手势。与词的点击、面板竖向滚动
  /// 各占一个手势方向,互不抢;快速甩动或明确拖过一段距离都算翻页,
  /// 轻慢的小拖动不算,免得误翻。到边界无动作(与按钮一致)。
  double? _swipeDistance;

  void _onSwipeUpdate(DragUpdateDetails details) {
    _swipeDistance = (_swipeDistance ?? 0) + details.delta.dx;
  }

  void _onSwipeEnd(DragEndDetails details) {
    final distance = _swipeDistance ?? 0;
    _swipeDistance = null;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity <= -500 || distance <= -100) {
      _moveSentence(1);
    } else if (velocity >= 500 || distance >= 100) {
      _moveSentence(-1);
    }
  }

  /// 假名标注:只认含假名(平/片)的读音。用户把「发音字符」设成罗马字
  /// 时 get_reading 会返回罗马字——那不是 furigana,直接当没有,词上方
  /// 留空、点击读汉字本身。
  static final RegExp _kanaPattern = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');

  String? _kanaReading(String? reading) {
    if (reading == null) return null;
    final r = reading.trim();
    if (r.isEmpty || !_kanaPattern.hasMatch(r)) return null;
    return r;
  }

  /// 正文那一行的强制行高(strut)。
  ///
  /// 为什么需要:每个词是「注音盒(13) + 正文」的 Column,整行按底边对齐
  /// (WrapCrossAlignment.end),所以**列高必须一致**,否则列高的词会把注音
  /// 顶上去。而正文行盒的高度并不总等于 fontSize*height——同一行里汉字和假名
  /// 若落到不同的回退字体,行高会取两者的 max(ascent)+max(descent),比纯汉字
  /// 或纯假名那一行更高。实测(OPPO PHB110,dpr 4)「青い」「広い」列高 25.0,
  /// 「地球」「世界」「の」「で」23.0 逻辑 px,差的 2px 就是注音高低不平的来源。
  /// 强制 strut 后所有词的行盒都等于 fontSize*height,注音与正文基线同时对齐。
  static final StrutStyle _wordStrut = StrutStyle.fromTextStyle(
    const TextStyle(fontSize: 19, height: 1.2),
    forceStrutHeight: true,
  );

  /// 点单词即发音:标注的假名优先(汉字按正确读音发声),没有假名
  /// 就读词本身。复用句子 TTS 通道,状态与播放条一致。
  ///
  /// 点下的词进入 _speaking 高亮,亮到 TTS 状态回 idle/error 为止
  /// (亮不亮由 sentenceTTSProvider 的 loading/playing 驱动,不用自己计时)。
  void _speakWord(String area, int index, String spoken) {
    if (spoken.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      // 新的一次点词作废胶囊两连读里还没接上的第二段。
      _pendingChipSpoken = null;
      _pendingChipIndex = null;
      _speaking = (area, index);
    });
    unawaited(
      ref
          .read(sentenceTTSProvider.notifier)
          .speakSentence(spoken, _sentence.sentenceId),
    );
  }

  /// 点判定胶囊:绿(读对)读这个词;琥珀(错读)先读正确读音、播完再
  /// 读实际听到的那个词;红(漏读)没有"听到的"可放,只读正确读音。
  ///
  /// 错词优先按它的假名注音发声:字面汉字丢给 TTS 会自挑读音(高山可能
  /// 被读成 たかやま),假名才是识别实际听到的那串音。两连读的第二段走
  /// _pendingChipSpoken,由 build 里的监听在第一段播完后接上。
  void _speakChip(
    int index,
    String token,
    ShadowingTokenStatus status,
    ShadowingResult result,
  ) {
    final readings = ref.read(shadowingProvider).readings;
    final correctKana = _kanaReading(
      (readings != null && index < readings.length)
          ? readings[index].reading
          : null,
    );
    final correct = correctKana ?? token.replaceAll('\u200B', '');
    if (correct.isEmpty) return;

    String? heard;
    if (status == ShadowingTokenStatus.fuzzy) {
      final heardText =
          (result.spokenForFuzzy[index] ?? '').replaceAll('\u200B', '');
      if (heardText.isNotEmpty) {
        ShadowingToken? heardToken;
        for (final t in result.transcriptionTokens) {
          if (t.text.replaceAll('\u200B', '') == heardText) {
            heardToken = t;
            break;
          }
        }
        heard = _kanaReading(heardToken?.reading) ?? heardText;
      }
    }

    HapticFeedback.selectionClick();
    setState(() {
      _pendingChipSpoken = heard;
      _pendingChipIndex = heard != null ? index : null;
      _speaking = (_areaChip, index);
    });
    unawaited(
      ref
          .read(sentenceTTSProvider.notifier)
          .speakSentence(correct, _sentence.sentenceId),
    );
  }

  /// 逐词渲染一句话:每个词上方是它的假名(没有则留同样高的空位),
  /// 整词是独立的点击目标,点一下读这个词。
  ///
  /// 对齐靠两件事同时成立:注音留位是定高的 SizedBox,正文行高由 _wordStrut
  /// 强制统一。少一个,列高就会随词变化,而 Wrap 是底对齐的,注音立刻高低不平。
  Widget _buildFuriganaSentence(
    String fallbackText,
    List<String> tokens,
    List<ShadowingToken>? readings,
    PlayerPalette palette, {
    required String area,
  }) {
    if (tokens.isEmpty) {
      return Text(
        fallbackText,
        style: TextStyle(color: palette.icon, fontSize: 19, height: 1.5),
      );
    }
    // 本句的 TTS 在合成/播放期间点亮点下的那个词;播完状态回 idle,高亮自然熄灭。
    final ttsState = ref.watch(sentenceTTSProvider);
    final speakingActive =
        ttsState.currentSentenceId == _sentence.sentenceId &&
        (ttsState.isLoading || ttsState.isPlaying);
    return Wrap(
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (var i = 0; i < tokens.length; i++)
          _buildWord(
            tokens[i].replaceAll('\u200B', ''),
            (readings != null && i < readings.length)
                ? readings[i].reading
                : null,
            palette,
            area: area,
            index: i,
            speaking: speakingActive && _speaking == (area, i),
            pressed: _pressed == (area, i),
          ),
      ],
    );
  }

  Widget _buildWord(
    String text,
    String? reading,
    PlayerPalette palette, {
    required String area,
    required int index,
    required bool speaking,
    required bool pressed,
  }) {
    final kana = _kanaReading(reading);
    // 两级反馈:按下先给浅底色(网络合成要一两秒,先承认这一下),开口后换
    // 跟读行同一块底色。墨水屏"靠形状不靠色",下边框常驻(不发音时透明),
    // 高亮亮灭不引起重排。
    final blockColor = speaking
        ? context.playingLineHighlight
        : pressed
        ? palette.groupFill
        : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = (area, index)),
      onTapUp: (_) => setState(() => _pressed = null),
      onTapCancel: () => setState(() => _pressed = null),
      onTap: () => _speakWord(area, index, kana ?? text),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Container(
          decoration: BoxDecoration(
            color: blockColor,
            borderRadius: BorderRadius.circular(4),
            border: context.eInk
                ? Border(
                    bottom: BorderSide(
                      color: speaking
                          ? context.playingLineText
                          : Colors.transparent,
                      width: 2,
                    ),
                  )
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 13,
                child: kana != null
                    ? Text(
                        kana,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 10,
                          height: 1.0,
                        ),
                      )
                    : null,
              ),
              Text(
                text,
                // 见 _wordStrut:不强制行高时,汉字+假名混排的词会因回退字体
                // 而比纯汉字/纯假名高一截,注音随之被顶高,整行高低不平。
                strutStyle: _wordStrut,
                style: TextStyle(
                  color: speaking ? context.playingLineText : palette.icon,
                  fontSize: 19,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(shadowingProvider);
    final ttsState = ref.watch(sentenceTTSProvider);
    final palette = context.playerPalette;

    // 结果超出视口时(长句、判定胶囊多行)把分数滚进可视区。等入场过渡
    // 走完再滚,否则目标位置按中途布局算会欠滚。
    ref.listen<ShadowingState>(shadowingProvider, (prev, next) {
      if (next.hasResult && !(prev?.hasResult ?? false)) {
        Future.delayed(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          final resultContext = _resultKey.currentContext;
          if (resultContext == null || !resultContext.mounted) return;
          Scrollable.ensureVisible(
            resultContext,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        });
      }
    });

    // 胶囊两连读的第二段:第一段播完(或失败)后状态回落,这里接上错词。
    ref.listen<SentenceTTSState>(sentenceTTSProvider, (prev, next) {
      if (_pendingChipSpoken == null) return;
      final wasActive = prev != null && (prev.isLoading || prev.isPlaying);
      final settled =
          next.status == SentenceTTSStatus.idle ||
          next.status == SentenceTTSStatus.error;
      if (!wasActive || !settled) return;
      final spoken = _pendingChipSpoken!;
      final index = _pendingChipIndex!;
      setState(() {
        _pendingChipSpoken = null;
        _pendingChipIndex = null;
        _speaking = (_areaChip, index);
      });
      unawaited(
        ref
            .read(sentenceTTSProvider.notifier)
            .speakSentence(spoken, _sentence.sentenceId),
      );
    });

    // 高度固定:从打开、出分到换句,面板框架一像素都不挪,分数只填进
    // 底部预留的空位 —— 不再随 take 生命周期长高缩回。
    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
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
        // translucent:空白区域(预留的结果槽)也要能接住滑动手势,
        // 同时不挡子级的点击。
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _onSwipeUpdate,
          onHorizontalDragEnd: _onSwipeEnd,
          onHorizontalDragCancel: () => _swipeDistance = null,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(context, palette),
                const SizedBox(height: 8),
                _buildSentenceText(state, palette),
                const SizedBox(height: 12),
                _buildControls(context, state, palette),
                _buildOutcomeZone(context, state, ttsState, palette),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 控件下方的唯一可变区:空提示、录音/转写状态、错误、评分结果四个
  /// 状态互斥轮换,同一槽位淡入淡出,互不推挤。墨水屏直接换内容,
  /// 不做过渡(每一帧局部刷新都留残影,与 term_tooltip 同一取舍)。
  Widget _buildOutcomeZone(
    BuildContext context,
    ShadowingState state,
    SentenceTTSState ttsState,
    PlayerPalette palette,
  ) {
    final Widget child;
    if (state.hasResult) {
      child = KeyedSubtree(
        key: const ValueKey('result'),
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: KeyedSubtree(
            key: _resultKey,
            child: _buildResult(context, state, palette),
          ),
        ),
      );
    } else if (state.error != null) {
      child = KeyedSubtree(
        key: const ValueKey('error'),
        child: _buildErrorBlock(context, state, palette),
      );
    } else if (state.isRecording || state.isProcessing) {
      child = KeyedSubtree(
        key: const ValueKey('status'),
        child: _buildStatusLine(state, palette),
      );
    } else if (ttsState.hasError && ttsState.errorMessage != null) {
      // 点词发音失败在这里交代:面板是弹层,ScaffoldMessenger 的 SnackBar
      // 会落在面板后面看不见;而合成失败是静默的,不提示用户分不清
      // "点了没反应"和"失败了"。再点一个词即自动清掉。
      child = KeyedSubtree(
        key: const ValueKey('ttsError'),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            ttsState.errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.errorInk, fontSize: 12),
          ),
        ),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('hint'),
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Text(
            'Your score appears here after you read the sentence.',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
        ),
      );
    }
    if (context.eInk) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      child: child,
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

  Widget _buildSentenceText(ShadowingState state, PlayerPalette palette) {
    return Container(
      width: double.infinity,
      // 最小高度按两行词预留:换句时行数不同(1↔2 行)也不再推挤下方控件。
      constraints: const BoxConstraints(minHeight: 104),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.groupFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: _sentenceSwap(
        _buildFuriganaSentence(
          _sentence.displayText,
          _sentence.tokens,
          state.readings,
          palette,
          area: _areaSentence,
        ),
      ),
    );
  }

  /// 换句时句子内容淡入淡出(滑动手势与按钮翻句共用),让翻页有反馈;
  /// 墨水屏直接换内容,不做过渡(残影)。假名标注稍后异步到达,
  /// key 不变,不会因此重播动画。
  Widget _sentenceSwap(Widget child) {
    if (context.eInk) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      child: KeyedSubtree(key: ValueKey(_currentIndex), child: child),
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
  /// 图标用 playInk:它和 playSurface 是一对(墨水屏=黑圆底白图标)。之前
  /// 空闲态误用 palette.icon——墨水屏下 icon=黑,黑圆底画黑 mic,整个图标
  /// 隐形,只剩一个大黑球,完全看不出是录音键(2026-10-03 Leaf 5C 反馈)。
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
          color: palette.playInk,
        ),
      ),
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
        _buildTokenChips(state, result, palette),
        if (result.languageNote != null) ...[
          const SizedBox(height: 8),
          Text(
            result.languageNote!,
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ],
        if (result.extras.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Also heard: ${result.extras.join(', ')}',
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Heard',
          style: TextStyle(
            color: palette.muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        _buildFuriganaSentence(
          result.transcription.isEmpty ? '--' : result.transcription,
          [for (final t in result.transcriptionTokens) t.text],
          result.transcriptionTokens.isEmpty ? null : result.transcriptionTokens,
          palette,
          area: _areaHeard,
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
  ///
  /// 每颗胶囊都是独立的点击目标,点一下发音(见 _speakChip:错读先读
  /// 正确读音再读听到的词);发音/按压期间换底色,与逐词渲染同一套反馈。
  Widget _buildTokenChips(
    ShadowingState state,
    ShadowingResult result,
    PlayerPalette palette,
  ) {
    final ttsState = ref.watch(sentenceTTSProvider);
    final speakingActive =
        ttsState.currentSentenceId == _sentence.sentenceId &&
        (ttsState.isLoading || ttsState.isPlaying);
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

      final speaking = speakingActive && _speaking == (_areaChip, i);
      final pressed = _pressed == (_areaChip, i);

      children.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = (_areaChip, i)),
          onTapUp: (_) => setState(() => _pressed = null),
          onTapCancel: () => setState(() => _pressed = null),
          onTap: () => _speakChip(i, token, status, result),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: speaking
                  ? context.playingLineHighlight
                  : pressed
                  ? palette.groupFill
                  : null,
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
        ),
      );
    }
    return Wrap(children: children);
  }
}
