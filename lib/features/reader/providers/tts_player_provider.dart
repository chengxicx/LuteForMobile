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

  const TTSPlayerState({
    this.snippets = const [],
    this.currentIndex = -1,
    this.positionInSnippet = Duration.zero,
    this.status = TTSPlayerStatus.idle,
    this.errorMessage,
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
  }) {
    return TTSPlayerState(
      snippets: snippets ?? this.snippets,
      currentIndex: currentIndex ?? this.currentIndex,
      positionInSnippet: positionInSnippet ?? this.positionInSnippet,
      status: status ?? this.status,
      errorMessage: clearError
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

class TTSPlayerNotifier extends Notifier<TTSPlayerState> {
  Timer? _positionTimer;
  StreamSubscription<PlayerState>? _serviceStateSubscription;
  bool _advanceOnComplete = false;

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
    final rate = _effectiveRate();
    final snippets = sentences.map((s) {
      return TTSPlayerSnippet(
        sentenceId: s.sentenceId,
        text: s.text,
        estimatedDuration: estimateDuration(s.text, rate),
      );
    }).toList();
    state = TTSPlayerState(snippets: snippets, currentIndex: -1);
  }

  double _effectiveRate() {
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

  Future<void> pause() async {
    _advanceOnComplete = false;
    _positionTimer?.cancel();
    _stopService();
    if (state.status == TTSPlayerStatus.playing ||
        state.status == TTSPlayerStatus.loading) {
      state = state.copyWith(status: TTSPlayerStatus.paused);
    }
  }

  Future<void> stop() async {
    _advanceOnComplete = false;
    _positionTimer?.cancel();
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
      await service.speak(snippet.text);
      if (state.status == TTSPlayerStatus.loading ||
          state.status == TTSPlayerStatus.playing) {
        state = state.copyWith(status: TTSPlayerStatus.playing);
        _startPositionTimer();
      }
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

  void _onServiceCompleted() {
    if (!_advanceOnComplete) return;
    // Only advance when a sentence actually finished (not on explicit stop,
    // which clears _advanceOnComplete first).
    if (state.status != TTSPlayerStatus.playing &&
        state.status != TTSPlayerStatus.loading) {
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
  }

  void _stopService() {
    final service = ref.read(ttsServiceProvider);
    unawaited(service.stop());
  }
}

final ttsPlayerProvider =
    NotifierProvider<TTSPlayerNotifier, TTSPlayerState>(() {
      return TTSPlayerNotifier();
    });