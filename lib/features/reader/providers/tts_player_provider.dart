import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/network/tts_service.dart';
import '../../../features/settings/providers/tts_settings_provider.dart';

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
    bool? loopMode,
    bool? autoPauseMode,
    double? playbackRate,
  }) {
    return TTSPlayerState(
      snippets: snippets ?? this.snippets,
      currentIndex: currentIndex ?? this.currentIndex,
      positionInSnippet: positionInSnippet ?? this.positionInSnippet,
      status: status ?? this.status,
      errorMessage: clearError
          ? null
          : (errorMessage ?? this.errorMessage),
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

  Timer? _positionTimer;
  StreamSubscription<PlayerState>? _serviceStateSubscription;
  bool _advanceOnComplete = false;

  /// Rate the user picked in the player bar, or null while the player still
  /// follows the TTS settings.  Kept here so turning the page does not
  /// quietly undo the user's choice.
  double? _userRate;

  /// When the current utterance was handed to the service, used to spot an
  /// "instant" completion (see [_instantCompletionThreshold]).
  DateTime? _speakStartedAt;

  int _instantLoopRepeats = 0;

  @override
  TTSPlayerState build() {
    ref.onDispose(() {
      _positionTimer?.cancel();
      _serviceStateSubscription?.cancel();
    });
    return const TTSPlayerState();
  }

  /// Loads a new set of sentences (one full page) and prepares playback.
  void loadPage(List<TTSPlayerSentence> sentences) {
    _resetPosition();
    _serviceStateSubscription?.cancel();
    final rate = _userRate ?? _rateFromSettings();
    final snippets = sentences.map((s) {
      return TTSPlayerSnippet(
        sentenceId: s.sentenceId,
        text: s.text,
        estimatedDuration: estimateDuration(s.text, rate),
      );
    }).toList();
    state = TTSPlayerState(
      snippets: snippets,
      currentIndex: -1,
      playbackRate: rate,
      loopMode: state.loopMode,
      autoPauseMode: state.autoPauseMode,
    );
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
    final cjk = RegExp(r'[\u3040-\u30FF\u4E00-\u9FFF\uAC00-\uD7AF]')
        .allMatches(text)
        .length;
    final other = text.length - cjk;
    final effRate = rate <= 0 ? 1.0 : rate;
    final seconds = (cjk * 0.4 + other * 0.09) / effRate;
    return Duration(milliseconds: (seconds.clamp(0.5, 120) * 1000).round());
  }

  /// Starts playing the whole page from the beginning.
  Future<void> play() async {
    if (!state.hasSnippets) return;
    _advanceOnComplete = true;
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

  Future<void> toggle() async {
    if (state.isPlaying || state.isLoading) {
      await pause();
    } else {
      await play();
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
    final clamped = rate
        .clamp(minPlaybackRate, maxPlaybackRate)
        .toDouble();
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
    _stopService();
    state = state.copyWith(
      currentIndex: -1,
      positionInSnippet: Duration.zero,
      status: TTSPlayerStatus.idle,
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

  Future<void> _speakCurrent() async {
    final snippet = state.currentSnippet;
    if (snippet == null) {
      _positionTimer?.cancel();
      _advanceOnComplete = false;
      state = state.copyWith(status: TTSPlayerStatus.idle);
      return;
    }

    _subscribeService();

    try {
      final service = ref.read(ttsServiceProvider);
      state = state.copyWith(status: TTSPlayerStatus.loading);
      // Set the rate right before speaking.  It is applied at utterance level
      // (FlutterTts / audioplayers), and a service rebuilt from the settings
      // would otherwise come back at the configured rate -- silently undoing
      // a rate the user picked in the player bar.
      await service.setPlaybackRate(state.playbackRate);
      _speakStartedAt = DateTime.now();
      await service.speak(snippet.text);
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
      // The server cannot synthesize this fragment (e.g. a sentence that was
      // split down to a single closing bracket). Treat it exactly like a normal
      // completion so the reader advances to the next sentence instead of
      // stalling on it.  There is no `playing` event to wait for on this path,
      // so completion handling is re-armed here.
      _advanceOnComplete = true;
      _onServiceCompleted();
    } catch (e) {
      _positionTimer?.cancel();
      state = state.copyWith(
        status: TTSPlayerStatus.error,
        errorMessage: e is TTSException ? e.message : e.toString(),
      );
    }
  }

  void _subscribeService() {
    _serviceStateSubscription?.cancel();
    final service = ref.read(ttsServiceProvider);
    _serviceStateSubscription = service.playerStateStream.listen((playerState) {
      if (playerState == PlayerState.completed ||
          playerState == PlayerState.stopped) {
        _onServiceCompleted();
      }
    });
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
      status: TTSPlayerStatus.loading,
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
        status: TTSPlayerStatus.loading,
      );
      unawaited(_speakCurrent());
    } else {
      _positionTimer?.cancel();
      _advanceOnComplete = false;
      state = state.copyWith(
        positionInSnippet: state.currentSnippet?.estimatedDuration ??
            state.positionInSnippet,
        status: TTSPlayerStatus.idle,
      );
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
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
    _speakStartedAt = null;
    _instantLoopRepeats = 0;
  }

  /// Stops the service we own, and disarms completion handling until the next
  /// utterance reports in.
  ///
  /// Stopping a player that is mid-utterance makes it report `stopped`, and
  /// that event does not necessarily arrive before we have re-subscribed for
  /// the sentence we are moving to.  Read as "that sentence finished" it
  /// advances a second time, one sentence past the one the user asked for.
  /// Clearing [_advanceOnComplete] here closes that window: it is re-armed by
  /// [_speakCurrent] once the next utterance has actually been handed over.
  /// Every caller either pauses/stops (where a completion must not advance)
  /// or is about to speak again.
  void _stopService() {
    _advanceOnComplete = false;
    final service = ref.read(ttsServiceProvider);
    unawaited(service.stop());
  }
}

final ttsPlayerProvider =
    NotifierProvider<TTSPlayerNotifier, TTSPlayerState>(() {
      return TTSPlayerNotifier();
    });