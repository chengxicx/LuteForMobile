import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/network/tts_service.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../../../shared/utils/tts_language_mapper.dart';
import '../../../features/settings/providers/tts_settings_provider.dart';
import 'current_book_provider.dart';

/// A raw sentence of the page, as gathered by the reader.  The provider
/// builds [TTSPlayerSnippet]s (with duration estimates) from these.
class TTSPlayerSentence {
  final int sentenceId;
  final String text;

  const TTSPlayerSentence({required this.sentenceId, required this.text});
}

/// A single sentence in the TTS read-aloud cue list.
///
/// `estimatedDuration` is a rough time-based estimate used to drive the
/// playhead on the timeline (web also estimates duration per cue).  The real
/// spoken audio may differ slightly; the estimate just keeps the bar moving.
class TTSPlayerSnippet {
  final int sentenceId;
  final String text;
  final Duration estimatedDuration;

  const TTSPlayerSnippet({
    required this.sentenceId,
    required this.text,
    required this.estimatedDuration,
  });
}

enum TTSPlayerStatus { idle, loading, playing, paused, error }

@immutable
class TTSPlayerState {
  final List<TTSPlayerSnippet> snippets;
  final int currentIndex;
  final Duration positionInSnippet;
  final TTSPlayerStatus status;
  final String? errorMessage;

  /// 本页朗读实际推给服务的语言标签（Edge TTS 的语言码）。
  ///
  /// 纯诊断用：报错文案会带上它，一眼能看出「书是日文、却在用 en」——
  /// release 包里 logcat 拿不到 debugPrint，只能靠界面把这件事说出来。
  final String? languageTag;

  /// 语言是从书里解析出来的；false = 用了设置页的兜底语言码（不是这本书的
  /// 语言，多半念不出来）。
  final bool languageResolved;

  /// 用户手动关掉了「语言未解析」这条提示（本页内不再打扰）。
  final bool languageNoticeDismissed;

  /// 动作性提示（「已切到本地语音」这类由事件写进来的），不是错误。
  final String? fallbackNotice;

  /// 播放条上要显示的中性提示。
  ///
  /// 「语言未解析」那一条是**算出来**的，不存：语言的解析是异步的（书架到货、
  /// `getLanguageById` 返回），`loadPage` 那一刻多半还没解析出来 —— 存下来就
  /// 会一直挂着「未解析」，而实际早就在用正确的语言读了。
  String? get notice {
    final action = fallbackNotice;
    if (action != null) return action;
    if (languageResolved || languageNoticeDismissed) return null;
    // 还没开口就不提示。语言是异步解析出来的（书架到货、`getLanguageById`
    // 返回），页面刚打开那一刻多半还没解析出来 —— 此时报「未解析」只是
    // 噪声：用户还没点播放，也就无所谓「按回退语言朗读」。
    if (status == TTSPlayerStatus.idle) return null;
    return '书的语言未解析，朗读按回退语言 ${languageTag ?? defaultTtsLanguageTag}';
  }

  /// Loop the sentence the playhead is on, restarting it when it ends.
  /// Mirrors the web player's Loop button.
  final bool loopMode;

  /// Stop at the end of every sentence, rewound to that sentence's start so
  /// pressing play reads it again.  Mirrors the web player's Auto-pause button.
  final bool autoPauseMode;

  /// Rate the player asks the TTS service to speak at.  Starts from the TTS
  /// settings and can be nudged in the player bar, like the web player's
  /// − / + rate control.
  final double playbackRate;

  const TTSPlayerState({
    this.snippets = const [],
    this.currentIndex = -1,
    this.positionInSnippet = Duration.zero,
    this.status = TTSPlayerStatus.idle,
    this.errorMessage,
    this.languageTag,
    this.languageResolved = true,
    this.languageNoticeDismissed = false,
    this.fallbackNotice,
    this.loopMode = false,
    this.autoPauseMode = false,
    this.playbackRate = 1.0,
  });

  bool get hasSnippets => snippets.isNotEmpty;
  bool get isPlaying => status == TTSPlayerStatus.playing;
  bool get isLoading => status == TTSPlayerStatus.loading;
  bool get canGoPrevious => currentIndex > 0;
  bool get canGoNext => currentIndex >= 0 && currentIndex < snippets.length - 1;

  TTSPlayerSnippet? get currentSnippet =>
      currentIndex >= 0 && currentIndex < snippets.length
      ? snippets[currentIndex]
      : null;

  /// Overall duration of the whole cue list (sum of estimates).
  Duration get totalDuration {
    var total = Duration.zero;
    for (final s in snippets) {
      total += s.estimatedDuration;
    }
    return total;
  }

  /// Overall playhead position = accumulated duration of completed sentences
  /// plus the current sentence's played amount.
  Duration get position {
    var acc = Duration.zero;
    for (var i = 0; i < currentIndex && i < snippets.length; i++) {
      acc += snippets[i].estimatedDuration;
    }
    return acc + positionInSnippet;
  }

  TTSPlayerState copyWith({
    List<TTSPlayerSnippet>? snippets,
    int? currentIndex,
    Duration? positionInSnippet,
    TTSPlayerStatus? status,
    String? errorMessage,
    bool clearError = false,
    String? languageTag,
    bool? languageResolved,
    bool? languageNoticeDismissed,
    String? fallbackNotice,
    bool clearFallbackNotice = false,
    bool? loopMode,
    bool? autoPauseMode,
    double? playbackRate,
  }) {
    return TTSPlayerState(
      snippets: snippets ?? this.snippets,
      currentIndex: currentIndex ?? this.currentIndex,
      positionInSnippet: positionInSnippet ?? this.positionInSnippet,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      languageTag: languageTag ?? this.languageTag,
      languageResolved: languageResolved ?? this.languageResolved,
      languageNoticeDismissed:
          languageNoticeDismissed ?? this.languageNoticeDismissed,
      fallbackNotice: clearFallbackNotice
          ? null
          : (fallbackNotice ?? this.fallbackNotice),
      loopMode: loopMode ?? this.loopMode,
      autoPauseMode: autoPauseMode ?? this.autoPauseMode,
      playbackRate: playbackRate ?? this.playbackRate,
    );
  }
}

class TTSPlayerNotifier extends Notifier<TTSPlayerState> {
  /// Rate range and step, matching the web player's − / + control
  /// (`ttsSetRate` clamps to 0.5 .. 2 and steps by 0.25).
  static const double minPlaybackRate = 0.5;
  static const double maxPlaybackRate = 2.0;
  static const double playbackRateStep = 0.25;

  /// A sentence that "finishes" sooner than this was never really voiced.
  /// The server answers 422 for a fragment edge-tts refuses to synthesize,
  /// and [_speakCurrent] turns that into a completion so the page keeps
  /// reading; looping such a cue would spin speak -> complete -> speak with
  /// no audio and no way out.
  static const Duration _instantCompletionThreshold = Duration(
    milliseconds: 250,
  );

  /// How many instant completions in a row we tolerate before giving up on
  /// looping the current sentence and advancing past it.
  static const int _maxInstantLoopRepeats = 3;

  /// 连续多少句「服务端说这句念不出来」（422）就判定为**服务端整体**念不
  /// 出来，而不是一句句孤立的碎片。
  ///
  /// 服务端对任何合成失败都答同一个 422（`lute/tts/routes.py` 里
  /// `except Exception -> 422`），于是「这句只剩一个 」」和「整页都念不出来」
  /// 在响应上长得一模一样：单句无法区分，一串可以 —— 真正的碎片是偶发的。
  /// 阈值取 3：连续 3 句都是碎片已经反常，也快到不至于让用户听完一整页
  /// 无声连播才发现不对。
  static const int _maxConsecutiveRefusals = 3;

  Timer? _positionTimer;
  StreamSubscription<PlayerState>? _serviceStateSubscription;

  /// 本地引擎的错误流订阅 —— 它不在 [playerStateStream] 上，见
  /// [_subscribeToService] 与 [OnDeviceTTSService.engineErrorStream]。
  StreamSubscription<TTSException>? _engineErrorSubscription;

  bool _advanceOnComplete = false;

  /// 连续被服务端拒答的句数；成功开口一句就清零。
  int _consecutiveRefusals = 0;

  /// 上一次被拒答的是哪一句。
  ///
  /// 同一句被反复拒答（循环模式在重播它）**不算**「整页念不出来」：那是
  /// 循环自己的事，它自带「连续 3 次瞬时完成就放行」的逃逸阀。只有连续
  /// 不同的句子都被拒，才说明是服务端整体念不出来。
  int? _lastRefusedIndex;

  /// 本页（本轮）显式拿到的书语言名，由 reader 直接传下来，优先于
  /// [currentBookProvider]。语言不该只在服务创建那一刻定一次。
  String? _bookLanguageName;

  /// 已经推给哪个服务实例、推的是哪个标签。省掉每句一次白跑的
  /// setLanguage（on-device 的那条会真的去切系统语音）。
  TTSService? _languageAppliedTo;
  String? _appliedLanguageTag;

  /// 服务端**明确拒答**（422）之后，本轮整页朗读改走本地引擎。
  ///
  /// 与「服务器不可达」分开记：不可达会自己恢复，所以每句都重新判一次；
  /// 拒答不会 —— 语言不对时，同一本书的下一句还是会被拒。
  bool _forceOnDeviceFallback = false;

  /// 是否启动 250ms 的位置心跳。墨水屏模式下 UI 传 false 关掉它：每 250ms
  /// 推一次状态就是每秒 4 次全屏重绘，朗读时屏幕会一直抖。
  bool _tickPosition = true;

  /// Audio already fetched but not yet spoken, keyed by snippet index.
  ///
  /// A network TTS service's [TTSService.speak] pays one full HTTP request
  /// first -- plus server-side synthesis when the server's cache misses --
  /// and until it returns there is nothing to play. That wait landed between
  /// every pair of sentences, which is why read-aloud "stops after every
  /// sentence" on mobile. The web player has no such gap: it synthesises in
  /// the browser from text already on the page.
  ///
  /// So fetch sentence N+1 while sentence N is being read. By the time N
  /// finishes, its successor is in memory and goes straight to the platform
  /// player through [TTSService.speakBytes].
  final Map<int, Uint8List> _prefetched = {};

  /// The service the cached bytes came from. A settings change rebuilds the
  /// service, possibly with another voice, language or endpoint; bytes from
  /// the previous one would then be wrong, so they are dropped.
  TTSService? _prefetchedOwner;

  /// Index whose audio is currently being fetched, so the same sentence is
  /// not requested twice.
  int? _prefetchingIndex;

  /// Service instance that last received the rate, and the rate it received.
  ///
  /// Every network service answers [TTSService.setPlaybackRate] with a call
  /// into the platform player, so doing it per sentence costs a round trip
  /// per sentence. Skipping it rests on `stop()` no longer calling
  /// `release()` -- see [TTSService.stop] -- because releasing tears down the
  /// player and with it the playback rate that was set.
  TTSService? _rateAppliedTo;
  double? _appliedRate;

  /// Rate the user picked in the player bar, or null while the player still
  /// follows the TTS settings.  Kept here so turning the page does not
  /// quietly undo the user's choice.
  double? _userRate;

  /// When the current utterance was handed to the service, used to spot an
  /// "instant" completion (see [_instantCompletionThreshold]).
  DateTime? _speakStartedAt;

  int _instantLoopRepeats = 0;

  /// 世代计数器：每次 stop／页面切换推进。[ _speakCurrent] 在 speak 的漫长
  /// 等待期间用户可能已按了下一句或暂停 —— 等待回来的旧调用凭此识别自己
  /// 已被取代，不再武装完成处理、不再改状态，否则迟到事件会被误读。
  int _transitionEpoch = 0;

  /// 「这句读完了」只认 `PlayerState.completed`，`stopped` 永远不算。
  ///
  /// 早先这里是一个 750ms 的时间窗：stop 在平台侧回的 `stopped` 回声经常
  /// 迟到，落在窗口外就被当成「这句读完了」。但窗口是个猜出来的数 —— 引擎
  /// 慢一点就漏，而漏一次就是平白跳过一句、高亮跑到音频前面。其实不必猜：
  /// `stopped` 从来就不是「读完」，它是「被叫停」；真正的完成永远以
  /// `completed` 报告。所以这里干脆不看 `stopped`，见 [_subscribeToService]。

  /// 在途的 stop future。下一条语句开口前先等它落地：引擎不保证 stop 先于
  /// 紧随的 speak/play 处理完，新语句可能被在途的 stop 冲掉。
  Future<void>? _pendingStop;

  /// 离线本地兜底引擎，懒建。主服务是 Edge TTS 而服务器不可达时，整页朗读
  /// 落到它身上，而不是每句都撞一遍注定超时的请求再整页报错 —— 与点词
  /// 发音链路（sentence_tts_provider）同一套思路。
  OnDeviceTTSService? _onDeviceFallback;

  /// 本句实际使用的服务。stop/订阅完成事件都要按它来：兜底引擎不在
  /// [ttsServiceProvider] 里，光停主服务停不掉它。
  TTSService? _activeService;

  @override
  TTSPlayerState build() {
    ref.onDispose(() {
      _positionTimer?.cancel();
      _serviceStateSubscription?.cancel();
      _engineErrorSubscription?.cancel();
      _onDeviceFallback?.dispose();
      _onDeviceFallback = null;
    });
    // 书的语言晚到就补一次诊断（自愈）。
    //
    // 语言名是异步解析出来的：页面加载那一刻书架可能还没到货，`loadPage`
    // 只能在「未解析」下建 state，而它以前要等到下一句开口才重算 —— 于是
    // 「打开书 → 还没点播放」这段时间里，播放条一直挂着「书的语言未解析」，
    // 与实际不符（真机上 nginx 收的已经是 /tts/ja-JP）。语言一解析出来就跟上；
    // 正在朗读时，下一句开口前 [_applyLanguage] 会把新语言推给服务。
    ref.listen(currentBookProvider, (_, next) {
      final name = next.languageName?.trim();
      if (name == null || name.isEmpty) return;
      final language = _resolveDisplayLanguage();
      if (language.resolved == state.languageResolved &&
          language.tag == state.languageTag) {
        return;
      }
      state = state.copyWith(
        languageTag: language.tag,
        languageResolved: language.resolved,
      );
    });
    return const TTSPlayerState();
  }

  /// 发音实际使用的服务：主服务；主服务是服务器型的 Edge TTS，且要么服务端
  /// 不可达、要么本轮已经被明确拒答时，改用本地兜底引擎。其他 provider
  /// （Kokoro/OpenAI/…）不是 Song 服务器的依赖，离线与否由各自的端点决定，
  /// 不在这里插手。
  ///
  /// 每句都重新解析「不可达」：服务器中途断线时，下一句自然落到本地兜底；
  /// 网络恢复时同样自然回到服务器。拒答是另一种情况，见
  /// [_forceOnDeviceFallback]。
  TTSService _resolveTTSService() {
    final primary = ref.read(ttsServiceProvider);
    if (primary is EdgeTTSService) {
      if (!ServerStatusManager.isReachable) {
        debugPrint('TTS player: server unreachable, using on-device engine');
        return _fallbackOnDeviceService();
      }
      if (_forceOnDeviceFallback) {
        debugPrint('TTS player: server refused, using on-device engine');
        return _fallbackOnDeviceService();
      }
    }
    return primary;
  }

  OnDeviceTTSService _fallbackOnDeviceService() {
    final existing = _onDeviceFallback;
    if (existing != null) return existing;
    final service = OnDeviceTTSService();
    _onDeviceFallback = service;
    return service;
  }

  /// 兜底引擎开口前的装配（语速用设置页 on-device 的 Rate）。与点词发音
  /// 链路共用 [prepareOnDeviceFallback]。
  ///
  /// 语言优先用 reader 直接传下来的那本书的语言：回退链上的名字可能正是
  /// 这个引擎被叫起来的原因（服务端念不出来 = 语言不对）。
  Future<void> _prepareFallbackService() async {
    final fallback = _onDeviceFallback;
    if (fallback == null) return;
    await prepareOnDeviceFallback(
      fallback,
      config: onDeviceConfigForFallback(ref.read(ttsSettingsProvider)),
      bookLanguageName:
          _bookLanguageName ?? ref.read(currentBookProvider).languageName,
    );
  }

  /// Loads a new set of sentences (one full page) and prepares playback.
  ///
  /// [bookLanguageName] 是 reader 从书/页面直接拿到的语言名。语言不该只在
  /// 服务创建那一刻定一次，也不该只靠「currentBookProvider 变了」这个监听
  /// 去追 —— 那条链上任何一步静默失败，就会一直用兜底语言码（默认 `en`）。
  /// 传下来的名字在 [_applyLanguage] 里于每句开口前推给服务。
  void loadPage(List<TTSPlayerSentence> sentences, {String? bookLanguageName}) {
    _resetPosition();
    _clearPrefetch();
    _serviceStateSubscription?.cancel();
    _engineErrorSubscription?.cancel();
    _bookLanguageName = bookLanguageName;
    _languageAppliedTo = null;
    _appliedLanguageTag = null;
    _resetRefusals();
    _forceOnDeviceFallback = false;
    final rate = _userRate ?? _rateFromSettings();
    final snippets = sentences.map((s) {
      // 多词词元文本里的零宽空格要在这里剥掉:snippet.text 是 speak、预取、
      // 时长估算三处共用的唯一文本源,入口归一化后三处自然一致。
      final text = normalizeTtsText(s.text);
      return TTSPlayerSnippet(
        sentenceId: s.sentenceId,
        text: text,
        estimatedDuration: estimateDuration(text, rate),
      );
    }).toList();
    final language = _resolveDisplayLanguage();
    state = TTSPlayerState(
      snippets: snippets,
      currentIndex: -1,
      playbackRate: rate,
      loopMode: state.loopMode,
      autoPauseMode: state.autoPauseMode,
      languageTag: language.tag,
      languageResolved: language.resolved,
    );
  }

  /// 诊断用：这本页会用的 Edge 语言标签，以及它是否真的从书里解析出来。
  ///
  /// `resolved == false` 就是「日文句子会被送去英文语音」的那一刻 —— 以前
  /// 这条路静默无声，只能靠服务端日志反推，现在直接显示在播放条上。
  ({String? tag, bool resolved}) _resolveDisplayLanguage() {
    final explicit = _bookLanguageName?.trim();
    final name = (explicit != null && explicit.isNotEmpty)
        ? explicit
        : ref.read(currentBookProvider).languageName?.trim();
    final resolved =
        name != null &&
        name.isNotEmpty &&
        ttsLanguageNameToTag.containsKey(name.toLowerCase());
    String? tag;
    try {
      tag = ref
          .read(ttsServiceProvider.notifier)
          .resolveEdgeLanguageCode(bookLanguageName: name);
    } catch (_) {
      tag = null;
    }
    return (tag: tag, resolved: resolved);
  }

  /// The rate configured in the TTS settings, used until the user picks one
  /// in the player bar.  Providers disagree on the field name (on-device
  /// speaks `rate`, kokoro/supertonic `speed`); the rest have no rate at all,
  /// which is why this falls back to 1.0.
  double _rateFromSettings() {
    try {
      final settings = ref.read(ttsSettingsProvider);
      final config = settings.providerConfigs[settings.provider];
      return config?.rate ?? config?.speed ?? 1.0;
    } catch (_) {
      return 1.0;
    }
  }

  static Duration estimateDuration(String text, double rate) {
    final cjk = RegExp(
      r'[\u3040-\u30FF\u4E00-\u9FFF\uAC00-\uD7AF]',
    ).allMatches(text).length;
    final other = text.length - cjk;
    final effRate = rate <= 0 ? 1.0 : rate;
    final seconds = (cjk * 0.4 + other * 0.09) / effRate;
    return Duration(milliseconds: (seconds.clamp(0.5, 120) * 1000).round());
  }

  /// Starts playing the whole page from the beginning.
  ///
  /// [tickPosition] = false 时不启动 250ms 的位置心跳（墨水屏模式）。句子
  /// 推进由服务的完成事件驱动，不受影响；只是不再有秒级进度可显示 ——
  /// 墨水屏上"第几句"比"第几秒"有用。
  Future<void> play({bool tickPosition = true}) async {
    if (!state.hasSnippets) return;
    _tickPosition = tickPosition;
    // 完成处理不在预武装：要等 [_speakCurrent] 真正把语句交给服务之后。
    // 预武装会让上一句的 stop 回声落在装载窗口里被误读为完成。
    if (state.currentIndex < 0) {
      state = state.copyWith(
        currentIndex: 0,
        positionInSnippet: Duration.zero,
        status: TTSPlayerStatus.loading,
        clearError: true,
      );
    } else {
      // Resume from the current sentence.
      state = state.copyWith(
        positionInSnippet: Duration.zero,
        status: TTSPlayerStatus.loading,
        clearError: true,
      );
    }
    await _speakCurrent();
  }

  Future<void> toggle({bool tickPosition = true}) async {
    if (state.isPlaying || state.isLoading) {
      await pause();
    } else {
      await play(tickPosition: tickPosition);
    }
  }

  /// Turn single-sentence looping on or off.
  ///
  /// Web behaviour, kept deliberately: turning loop **on** while the player
  /// sits paused at the end of a sentence (the auto-pause case) starts the
  /// loop straight away rather than waiting for another press of play --
  /// "press loop to keep looping".  Turning it off never pauses.
  Future<void> toggleLoopMode() async {
    final newLoop = !state.loopMode;
    state = state.copyWith(loopMode: newLoop);

    if (newLoop &&
        state.status == TTSPlayerStatus.paused &&
        state.currentSnippet != null) {
      await play();
    }
  }

  /// Turn the end-of-sentence pause on or off.  Loop wins when both are on,
  /// matching the web player (`media-player-base.js`, `ttsAdvance`).
  void toggleAutoPauseMode() {
    state = state.copyWith(autoPauseMode: !state.autoPauseMode);
  }

  /// Nudge the speaking rate by [delta], or jump straight to [rate].
  ///
  /// Ranges and the 0.25 step mirror the web player's − / + control.  The
  /// rate is pushed to the service and, when something is playing, the
  /// current sentence restarts so the change is audible immediately --
  /// a plain `setSpeechRate`/`setPlaybackRate` only affects the *next*
  /// utterance.
  Future<void> setPlaybackRate(double rate) async {
    final clamped = rate.clamp(minPlaybackRate, maxPlaybackRate).toDouble();
    if (clamped == state.playbackRate) return;

    _userRate = clamped;
    _reestimateDurations(clamped);
    state = state.copyWith(playbackRate: clamped);

    if (state.isPlaying || state.isLoading) {
      await _restartCurrent();
    }
  }

  Future<void> nudgePlaybackRate(double delta) =>
      setPlaybackRate(state.playbackRate + delta);

  /// Back to 1.0x, the same "click the number to reset" affordance the web
  /// player's rate indicator has.
  Future<void> resetPlaybackRate() async {
    _userRate = null;
    final base = _rateFromSettings();
    if (base == state.playbackRate) return;

    _reestimateDurations(base);
    state = state.copyWith(playbackRate: base);

    if (state.isPlaying || state.isLoading) {
      await _restartCurrent();
    }
  }

  /// Re-estimates every sentence not yet measured against a new rate, so the
  /// timeline stays consistent.  Web does the same in `ttsSetRate`.
  void _reestimateDurations(double rate) {
    final updated = state.snippets
        .map(
          (s) => TTSPlayerSnippet(
            sentenceId: s.sentenceId,
            text: s.text,
            estimatedDuration: estimateDuration(s.text, rate),
          ),
        )
        .toList();
    state = state.copyWith(snippets: updated);
  }

  /// Re-speak the current sentence from its start, e.g. after a rate change.
  Future<void> _restartCurrent() async {
    if (state.currentSnippet == null) return;
    _positionTimer?.cancel();
    _stopService();
    state = state.copyWith(
      positionInSnippet: Duration.zero,
      status: TTSPlayerStatus.loading,
    );
    await _speakCurrent();
  }

  Future<void> pause() async {
    _advanceOnComplete = false;
    _positionTimer?.cancel();
    _speakStartedAt = null;
    _instantLoopRepeats = 0;
    _stopService();
    if (state.status == TTSPlayerStatus.playing ||
        state.status == TTSPlayerStatus.loading) {
      state = state.copyWith(status: TTSPlayerStatus.paused);
    }
  }

  Future<void> stop() async {
    _advanceOnComplete = false;
    _positionTimer?.cancel();
    _speakStartedAt = null;
    _instantLoopRepeats = 0;
    // 一次朗读结束：拒答计数与「本轮改走本地」都清零，下次播放重新试主服务
    // （用户可能刚把语言设置改对了）。
    _resetRefusals();
    _forceOnDeviceFallback = false;
    _languageAppliedTo = null;
    _appliedLanguageTag = null;
    _clearPrefetch();
    _stopService();
    state = state.copyWith(
      currentIndex: -1,
      positionInSnippet: Duration.zero,
      status: TTSPlayerStatus.idle,
      clearFallbackNotice: true,
    );
  }

  /// 只清除报错条,不动播放状态(报错行末尾的"关闭"按钮用)。
  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  /// 只清除中性提示（语言未解析 / 已切本地语音），不动播放状态。
  ///
  /// 「语言未解析」那条是算出来的，所以除了清掉动作性提示，还要记下「用户
  /// 已经看过并关掉了」，否则下一次 setState 它又会冒出来。
  void dismissNotice() {
    if (state.notice == null) return;
    state = state.copyWith(
      clearFallbackNotice: true,
      languageNoticeDismissed: true,
    );
  }

  Future<void> next() async {
    if (!state.canGoNext) return;
    _positionTimer?.cancel();
    _stopService();
    final nextIndex = state.currentIndex + 1;
    state = state.copyWith(
      currentIndex: nextIndex,
      positionInSnippet: Duration.zero,
      status: state.isPlaying || state.isLoading
          ? TTSPlayerStatus.loading
          : TTSPlayerStatus.paused,
    );
    if (state.isLoading || state.isPlaying) {
      await _speakCurrent();
    }
  }

  Future<void> previous() async {
    if (!state.canGoPrevious) return;
    _positionTimer?.cancel();
    _stopService();
    final prevIndex = state.currentIndex - 1;
    state = state.copyWith(
      currentIndex: prevIndex,
      positionInSnippet: Duration.zero,
      status: state.isPlaying || state.isLoading
          ? TTSPlayerStatus.loading
          : TTSPlayerStatus.paused,
    );
    if (state.isLoading || state.isPlaying) {
      await _speakCurrent();
    }
  }

  /// Jumps to a sentence by index and (re)starts it if playing.
  Future<void> seekTo(int index) async {
    if (index < 0 || index >= state.snippets.length) return;
    final wasPlaying = state.isPlaying || state.isLoading;
    _positionTimer?.cancel();
    _stopService();
    state = state.copyWith(
      currentIndex: index,
      positionInSnippet: Duration.zero,
      status: wasPlaying ? TTSPlayerStatus.loading : TTSPlayerStatus.paused,
    );
    if (wasPlaying) {
      await _speakCurrent();
    }
  }

  Future<void> _speakCurrent({bool allowFallbackRetry = true}) async {
    final snippet = state.currentSnippet;
    if (snippet == null) {
      _positionTimer?.cancel();
      _advanceOnComplete = false;
      state = state.copyWith(status: TTSPlayerStatus.idle);
      return;
    }

    // 归一化后什么都不剩的句子不能送去合成：它拼出来是 `/tts/<lang>/`，末段
    // 为空，服务端的 path 转换器（要求至少一个字符）同样匹配不上 → 404 →
    // 被当成真实错误弹横幅、卡住整页。这类"幽灵句"在页面上只占标点或空白，
    // 本来就没有可读内容。
    //
    // 走「不可发音碎片」那条路：当作正常播完，推进下一句。网页播放器也是先
    // 判空再 advance（`tts-player.js`: `if (!cleanText) { ttsAdvance(); return; }`）。
    // 推进是 `unawaited(_speakCurrent())`，所以连着一串空句也不会递归爆栈。
    if (snippet.text.isEmpty) {
      _advanceOnComplete = true;
      _onServiceCompleted();
      return;
    }

    // 本调用所属的世代。speak 的等待期间用户可能已切换／暂停（都会推进
    // 世代），等回来的这里已是过时请求，不得再武装完成处理或改状态。
    final epoch = _transitionEpoch;

    try {
      final service = _resolveTTSService();
      _activeService = service;
      // 完成事件始终从本句实际使用的服务的流上收：兜底引擎不在
      // [ttsServiceProvider] 里，光订阅主服务收不到它的完成事件。
      _subscribeToService(service);

      // Cached bytes belong to one service instance; anything fetched before
      // a rebuild can carry a different voice or language than the one now
      // selected, and must not be played.
      if (_prefetchedOwner != null && _prefetchedOwner != service) {
        _clearPrefetch();
      }
      _prefetchedOwner = service;

      // Prefetched audio is looked up, not consumed: Loop replays this very
      // sentence, and taking its bytes away would send the second pass back
      // through the network. Entries behind the playhead are dropped when the
      // next one is fetched.
      //
      // 预取命中就不亮 loading：音频已经在手机上，交给播放器是平台调用，
      // 没有任何网络等待。原来这里在 speak 之前**无条件**设 loading，于是
      // 每切一句按钮都会先转一圈再变回来 —— 预取省掉的等待是真的，省掉的
      // 那段 loading 却是假的，看起来就像预取没生效。真正要等（本地兜底
      // 引擎装配、没有预取字节要去网络取）才把它亮出来。
      final prefetched = _prefetched[state.currentIndex];
      if (prefetched == null) {
        state = state.copyWith(status: TTSPlayerStatus.loading);
      }

      await _applyPlaybackRate(service);
      if (epoch != _transitionEpoch) return;
      // 语言每句开口前推一次：服务是旧实例、或语言解析晚到，都能在这一刻
      // 纠正过来，而不是永远停在创建时那个值（那是「整页无声」的根）。
      await _applyLanguage(service);
      if (epoch != _transitionEpoch) return;

      final usingFallback = !identical(service, ref.read(ttsServiceProvider));
      if (usingFallback) {
        // 兜底引擎要重新装配（setSettings/setLanguage 会真的去切系统语音），
        // 这一段有等待，如实亮 loading。
        if (state.status != TTSPlayerStatus.loading) {
          state = state.copyWith(status: TTSPlayerStatus.loading);
        }
        await _prepareFallbackService();
        if (epoch != _transitionEpoch) return;
      }

      // 先等上一次 stop 落地再开口。引擎不保证 stop 先于紧随的 speak/play
      // 处理完，新语句可能被在途的 stop 冲掉 —— 进度心跳照走，声音却不再来。
      final stopToSettle = _pendingStop;
      if (stopToSettle != null) {
        _pendingStop = null;
        await stopToSettle.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        if (epoch != _transitionEpoch) return;
      }

      _speakStartedAt = DateTime.now();
      if (prefetched != null) {
        await service.speakBytes(prefetched);
      } else {
        await service.speak(snippet.text);
      }
      if (epoch != _transitionEpoch) return;
      // 服务收下了这句话 → 「连续被拒答」清零（碎片是偶发的，不是常态）。
      _resetRefusals();
      unawaited(_prefetchNext());
      // The service has taken this utterance.  From here a completion belongs
      // to *it*, not to the sentence we stopped in order to get here -- see
      // [_stopService].  Re-armed only after speak() has returned, so the
      // late `stopped` of the previous utterance (which lands while this
      // speak() is still fetching) is ignored instead of advancing twice.
      _advanceOnComplete = true;
      if (state.status == TTSPlayerStatus.loading ||
          state.status == TTSPlayerStatus.playing) {
        state = state.copyWith(status: TTSPlayerStatus.playing);
        _startPositionTimer();
      }
    } on TTSUnpronounceableFragmentException {
      if (epoch != _transitionEpoch) return;
      final attemptedBefore = _lastRefusedIndex == state.currentIndex;
      final refusals = _noteRefusal();

      // 第一次被拒：先原句重试一次再判死刑。
      //
      // 服务端对**完全正常**的句子也会偶发地答 422：实测同一页里
      // 「しかし、誰もいません。」在 ja-JP 下被拒过一次，同一 URL 重试立刻
      // 200（24.9 KB 音频）。直接当成碎片跳过，用户就白丢一句 —— 重试一次
      // 就能把它读回来。
      if (!attemptedBefore) {
        await _speakCurrent(allowFallbackRetry: false);
        return;
      }

      // 重试仍被拒：认下这句读不出来当作播完，推进下一句（这条路上没有
      // `playing` 事件可等，所以完成处理在这里重新武装）。
      // 连着**不同**的句子都被拒则是另一回事，见 [_escalateRefusal]。
      if (refusals >= _maxConsecutiveRefusals) {
        await _escalateRefusal();
        return;
      }
      _advanceOnComplete = true;
      _onServiceCompleted();
    } catch (e) {
      if (epoch != _transitionEpoch) return;
      // 主服务（Edge TTS）这句中途失败、且服务器此刻已判不可达：换本地
      // 兜底引擎把这句读出来，而不是弹横幅卡住整页。只递归重试一次
      // （兜底引擎自己再失败就走正常报错）。
      final primary = ref.read(ttsServiceProvider);
      final usedFallback = _onDeviceFallback != null &&
          identical(_activeService, _onDeviceFallback);
      if (allowFallbackRetry &&
          !usedFallback &&
          primary is EdgeTTSService &&
          !ServerStatusManager.isReachable) {
        await _speakCurrent(allowFallbackRetry: false);
        return;
      }
      _positionTimer?.cancel();
      state = state.copyWith(
        status: TTSPlayerStatus.error,
        errorMessage: e is TTSException ? e.message : e.toString(),
      );
    }
  }

  /// Push the rate to the service only when it has actually changed.
  ///
  /// Applied at utterance level (FlutterTts / audioplayers), and a service
  /// rebuilt from the settings comes back at the configured rate -- so a rate
  /// the user picked in the player bar still has to be re-applied whenever the
  /// service instance itself changes, not just when the number changed.
  ///
  /// 本地兜底引擎是例外：它的语速由设置页 on-device 的 Rate 决定（见
  /// [_prepareFallbackService]）。播放器倍率是网络音频的播放速度，推给
  /// flutter_tts 会错标刻度（1.0 -> 平台 2 倍速），跳过。
  Future<void> _applyPlaybackRate(TTSService service) async {
    if (!identical(service, ref.read(ttsServiceProvider))) return;
    if (_rateAppliedTo == service && _appliedRate == state.playbackRate) return;
    await service.setPlaybackRate(state.playbackRate);
    _rateAppliedTo = service;
    _appliedRate = state.playbackRate;
  }

  /// 把语言推给主服务 —— 只对 Edge TTS 生效（其余 provider 的语言由各自的
  /// 设置决定，插一手会改变它们既有行为；on-device 的 setLanguage 会真的去
  /// 切系统语音，那条走 [prepareOnDeviceFallback]）。
  ///
  /// 只在标签变化时才推：`EdgeTTSService.setLanguage` 本身是本地字段赋值，
  /// 但没必要每句都改一次状态。
  Future<void> _applyLanguage(TTSService service) async {
    final language = _resolveDisplayLanguage();
    final tag = language.tag ?? defaultTtsLanguageTag;

    // 诊断字段（播放条上的语言提示）与服务无关，先更新。本地兜底引擎不接
    // 受语言推送，但它念得对不对同样取决于这本书的语言有没有解析出来 ——
    // 以前这里一开头就 `return`，于是切到 On Device 朗读时，播放条永远停在
    // `loadPage` 那一刻的「未解析」，与实际不符。
    if (state.languageTag != tag ||
        state.languageResolved != language.resolved) {
      state = state.copyWith(
        languageTag: tag,
        languageResolved: language.resolved,
      );
    }

    // 只有 Edge TTS 需要把语言推给服务：其余 provider 的语言由各自的
    // setSettings 决定，在这里插一手会改变它们既有行为（on-device 的
    // setLanguage 会真的去切系统语音，那条走 prepareOnDeviceFallback）。
    if (service is! EdgeTTSService) return;
    if (_languageAppliedTo == service && _appliedLanguageTag == tag) return;
    await ref
        .read(ttsServiceProvider.notifier)
        .syncEdgeLanguage(bookLanguageName: _bookLanguageName);
    _languageAppliedTo = service;
    _appliedLanguageTag = tag;
  }

  /// 记一次「服务端说这句念不出来」，返回**连续不同句**被拒的次数。
  ///
  /// 同一句反复被拒不算（循环模式在重播它，它自带逃逸阀），见
  /// [_lastRefusedIndex]。
  int _noteRefusal() {
    final index = state.currentIndex;
    if (_lastRefusedIndex != index) {
      _lastRefusedIndex = index;
      _consecutiveRefusals++;
    }
    return _consecutiveRefusals;
  }

  void _resetRefusals() {
    _consecutiveRefusals = 0;
    _lastRefusedIndex = null;
  }

  /// 服务端连续拒答（422）之后的处置：不再当作「碎片」一句句跳过。
  ///
  /// 先试着把这句交给本地引擎读出来（服务端点不出来的原因多半是语言不对，
  /// 本地引擎不受这个限制），兜底也起不来才停下报错。两条路都比「无声地
  /// 把整页跑完」好 —— 那正是这个分支存在的原因。
  Future<void> _escalateRefusal() async {
    _resetRefusals();
    final primary = ref.read(ttsServiceProvider);
    final usingFallback =
        _activeService != null && identical(_activeService, _onDeviceFallback);

    if (!usingFallback && primary is EdgeTTSService) {
      _forceOnDeviceFallback = true;
      state = state.copyWith(
        status: TTSPlayerStatus.loading,
        clearError: true,
        fallbackNotice:
            '服务端连续念不出来（语言 ${state.languageTag ?? defaultTtsLanguageTag}），已切到本地语音',
      );
      await _speakCurrent(allowFallbackRetry: false);
      // 兜底成功 → 这里已经是 playing；兜底自己也失败 → _speakCurrent 已经
      // 把 status 置成 error 并带上原因。两种情况都不需要再做别的。
      return;
    }

    _positionTimer?.cancel();
    _advanceOnComplete = false;
    _speakStartedAt = null;
    state = state.copyWith(
      status: TTSPlayerStatus.error,
      errorMessage:
          '连续 $_maxConsecutiveRefusals 句被服务端拒答（语言 '
          '${state.languageTag ?? '未知'}）。朗读已停下，没有静默跳过；'
          '请检查这本书的语言设置，或换一个 TTS 引擎。',
    );
  }

  /// Fetch the sentence after the playhead in the background.
  ///
  /// Failure here is silent and deliberately so: a prefetch that fails leaves
  /// the sentence to be spoken the old way, one network request's worth of
  /// waiting later. Nothing about the failure belongs to the sentence being
  /// read *now*, which is what the user is listening to.
  Future<void> _prefetchNext() async {
    final index = state.currentIndex + 1;
    if (index < 1 || index >= state.snippets.length) return;
    if (_prefetched.containsKey(index) || _prefetchingIndex == index) return;

    final TTSService service;
    try {
      service = _resolveTTSService();
    } catch (_) {
      return;
    }
    if (!service.supportsBytesOutput) return;

    _prefetchingIndex = index;
    try {
      final bytes = await service.getAudioBytes(state.snippets[index].text);
      // Kept as long as the sentence still lies at or ahead of the playhead.
      // Anything behind it is dead weight and dropped. Note this is *not* a
      // check that we are still on the previous sentence: a short sentence
      // can finish before the fetch does, and throwing those bytes away is
      // exactly how short sentences lose the prefetch's benefit. Keeping them
      // costs nothing -- they are keyed by index and only ever played for the
      // sentence they were fetched for.
      if (bytes.isNotEmpty && index >= state.currentIndex) {
        _prefetched.removeWhere((key, _) => key < state.currentIndex);
        _prefetched[index] = bytes;
        _prefetchedOwner = service;
      }
    } catch (e) {
      debugPrint('TTS prefetch failed for sentence $index: $e');
    } finally {
      if (_prefetchingIndex == index) _prefetchingIndex = null;
    }
  }

  void _clearPrefetch() {
    _prefetched.clear();
    _prefetchedOwner = null;
    _prefetchingIndex = null;
  }

  /// 订阅「本句实际使用的服务」的完成与错误事件。
  ///
  /// 完成事件始终从本句实际使用的服务上收：兜底引擎不在 [ttsServiceProvider]
  /// 里，光订阅主服务收不到它的完成事件。
  void _subscribeToService(TTSService service) {
    _serviceStateSubscription?.cancel();
    _engineErrorSubscription?.cancel();
    _serviceStateSubscription = service.playerStateStream.listen((playerState) {
      // 只有 completed 是「这句读完了」。stopped 是「被叫停」：既包括我们
      // 自己 stop 的回声，也包括 on-device 引擎报错（它以前就发 stopped，
      // 于是「引擎报错」被读成「播完」—— 高亮一路往前走，却一点声音都没有）。
      // 回声会迟到多久算不出来，所以不猜：`stopped` 一律不当完成。
      if (playerState != PlayerState.completed) return;
      _onServiceCompleted();
    });

    // 引擎错误走自己的通道（见 OnDeviceTTSService.engineErrorStream）：报错
    // 必须让朗读停下来报错，而不是当作播完继续往下念。
    if (service is OnDeviceTTSService) {
      _engineErrorSubscription = service.engineErrorStream.listen(
        _onEngineError,
      );
    }
  }

  /// 引擎自己报错：停下并说出来，绝不当作「这句读完了」。
  void _onEngineError(TTSException error) {
    if (state.status != TTSPlayerStatus.playing &&
        state.status != TTSPlayerStatus.loading) {
      return;
    }
    _positionTimer?.cancel();
    _advanceOnComplete = false;
    _speakStartedAt = null;
    state = state.copyWith(
      status: TTSPlayerStatus.error,
      errorMessage: error.message,
    );
  }

  /// Whether the loop should replay the current sentence, as opposed to
  /// falling through to a normal advance.
  ///
  /// The only reason to say no is a cue that keeps "finishing" the instant it
  /// starts: the service never voiced it, so looping it would spin with no
  /// audio and never move on.
  bool _shouldReplayCurrentForLoop() {
    final started = _speakStartedAt;
    if (started == null) return true;

    final elapsed = DateTime.now().difference(started);
    if (elapsed >= _instantCompletionThreshold) {
      _instantLoopRepeats = 0;
      return true;
    }

    _instantLoopRepeats++;
    if (_instantLoopRepeats <= _maxInstantLoopRepeats) return true;
    _instantLoopRepeats = 0;
    return false;
  }

  Future<void> _replayCurrentForLoop() async {
    state = state.copyWith(
      positionInSnippet: Duration.zero,
      // 循环重播用的就是本句已经预取好的字节，同样不亮 loading
      //（理由见 [_speakCurrent]）。
      status: _prefetched.containsKey(state.currentIndex)
          ? state.status
          : TTSPlayerStatus.loading,
      clearError: true,
    );
    await _speakCurrent();
  }

  void _onServiceCompleted() {
    if (!_advanceOnComplete) return;
    // Only advance when a sentence actually finished (not on explicit stop,
    // which clears _advanceOnComplete first).
    if (state.status != TTSPlayerStatus.playing &&
        state.status != TTSPlayerStatus.loading) {
      return;
    }

    // Loop beats auto-pause when both are on: the sentence repeats instead of
    // stopping.  Same precedence as the web player.
    if (state.loopMode &&
        state.currentSnippet != null &&
        _shouldReplayCurrentForLoop()) {
      unawaited(_replayCurrentForLoop());
      return;
    }

    if (state.autoPauseMode) {
      // Stop at the end of this sentence and rewind to its start, so pressing
      // play reads it again.  Clearing _advanceOnComplete is what makes that
      // press a fresh start rather than a continuation.
      _positionTimer?.cancel();
      _advanceOnComplete = false;
      _speakStartedAt = null;
      state = state.copyWith(
        positionInSnippet: Duration.zero,
        status: TTSPlayerStatus.paused,
      );
      return;
    }

    if (state.canGoNext) {
      final nextIndex = state.currentIndex + 1;
      state = state.copyWith(
        currentIndex: nextIndex,
        positionInSnippet: Duration.zero,
        // 下一句已经预取好了就不亮 loading —— 音频在本机，切句是无缝的。
        // 这里原来无条件设 loading，于是预取命中的句子也会先转一下圈；
        // 真正需要等的时候由 [_speakCurrent] 自己把 loading 亮出来。
        status: _prefetched.containsKey(nextIndex)
            ? state.status
            : TTSPlayerStatus.loading,
      );
      unawaited(_speakCurrent());
    } else {
      _positionTimer?.cancel();
      _advanceOnComplete = false;
      state = state.copyWith(
        positionInSnippet:
            state.currentSnippet?.estimatedDuration ?? state.positionInSnippet,
        status: TTSPlayerStatus.idle,
      );
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    if (!_tickPosition) return;
    final snippet = state.currentSnippet;
    if (snippet == null) return;
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final current = state.currentSnippet;
      if (current == null) {
        _positionTimer?.cancel();
        return;
      }
      var newPos = state.positionInSnippet + const Duration(milliseconds: 250);
      // Clamp at the estimated duration; the completion event drives the
      // actual advance, so only bump a little past and bounce back.
      if (newPos >= current.estimatedDuration) {
        newPos = current.estimatedDuration;
      }
      state = state.copyWith(positionInSnippet: newPos);
    });
  }

  void _resetPosition() {
    _positionTimer?.cancel();
    _advanceOnComplete = false;
    _transitionEpoch++;
    _speakStartedAt = null;
    _instantLoopRepeats = 0;
  }

  /// Stops the service we own, and disarms completion handling until the next
  /// utterance reports in.
  ///
  /// Stopping a player that is mid-utterance makes it report `stopped`, and
  /// that event does not necessarily arrive before we have re-subscribed for
  /// the sentence we are moving to.  Clearing [_advanceOnComplete] here keeps
  /// that echo harmless: it is re-armed by [_speakCurrent] once the next
  /// utterance has actually been handed over.  (The echo is *also* ignored
  /// outright now — see [_subscribeToService]: only `completed` ever counts as
  /// "this sentence finished".  The two together mean a late stop can neither
  /// advance twice nor advance at all.)  Every caller either pauses/stops
  /// (where a completion must not advance) or is about to speak again.
  ///
  /// Each call also bumps [_transitionEpoch] (invalidating any in-flight
  /// speak) and records the in-flight stop in [_pendingStop] — the next
  /// utterance settles it before speaking, so the engine-side stop can never
  /// land on top of the new utterance and mute it.
  void _stopService() {
    _advanceOnComplete = false;
    _transitionEpoch++;
    // 本句若走的是本地兜底实例，得停它本身 —— 它不在 [ttsServiceProvider]
    // 里，停主服务停不掉它。主服务也顺手停一下：它的播放器可能还压着
    // 上一句的网络音频。
    final primary = ref.read(ttsServiceProvider);
    final active = _activeService;
    final stopFuture = active != null && !identical(active, primary)
        ? active.stop()
        : primary.stop();
    _pendingStop = stopFuture.catchError((Object _) {});
    unawaited(_pendingStop);
  }
}

final ttsPlayerProvider = NotifierProvider<TTSPlayerNotifier, TTSPlayerState>(
  () {
    return TTSPlayerNotifier();
  },
);
