import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/core/network/tts_service.dart';
import 'package:song_mobile/core/providers/tts_provider.dart';
import '../providers/audio_player_provider.dart';

enum SentenceTTSStatus { idle, loading, playing, error }

@immutable
class SentenceTTSState {
  final SentenceTTSStatus status;
  final String? errorMessage;
  final String? currentText;
  final int? currentSentenceId;
  final int retryCount;
  final bool isFallenBackToNone;
  final BytesSource? ttsAudioSource;

  const SentenceTTSState({
    this.status = SentenceTTSStatus.idle,
    this.errorMessage,
    this.currentText,
    this.currentSentenceId,
    this.retryCount = 0,
    this.isFallenBackToNone = false,
    this.ttsAudioSource,
  });

  bool get isPlaying => status == SentenceTTSStatus.playing;
  bool get isLoading => status == SentenceTTSStatus.loading;
  bool get hasError => status == SentenceTTSStatus.error;

  SentenceTTSState copyWith({
    SentenceTTSStatus? status,
    String? errorMessage,
    String? currentText,
    int? currentSentenceId,
    int? retryCount,
    bool? isFallenBackToNone,
    BytesSource? ttsAudioSource,
  }) {
    return SentenceTTSState(
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      currentText: currentText ?? this.currentText,
      currentSentenceId: currentSentenceId ?? this.currentSentenceId,
      retryCount: retryCount ?? this.retryCount,
      isFallenBackToNone: isFallenBackToNone ?? this.isFallenBackToNone,
      ttsAudioSource: ttsAudioSource ?? this.ttsAudioSource,
    );
  }
}

class SentenceTTSNotifier extends Notifier<SentenceTTSState> {
  static const int maxRetries = 3;

  @override
  SentenceTTSState build() {
    ref.onDispose(() {
      _playerStateSubscription?.cancel();
      _completeSubscription?.cancel();
      _ttsServiceStateSubscription?.cancel();
      _ttsPlayerInstance?.dispose();
      _ttsPlayerInstance = null;
    });
    return const SentenceTTSState();
  }

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<PlayerState>? _ttsServiceStateSubscription;

  /// 发音专用的播放器。它刻意与 MP3 有声书的 [audioPlayerProvider] 分开:
  /// 共用一个播放器时,发音字节流会替换掉已加载的书籍音源,之后按 MP3 的
  /// 播放键只是 resume,会播出 TTS 的声音。
  AudioPlayer? _ttsPlayerInstance;
  AudioPlayer get _ttsPlayer {
    final existing = _ttsPlayerInstance;
    if (existing != null) return existing;
    final player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _ttsPlayerInstance = player;
    return player;
  }

  /// 书籍音频在播时先暂停(位置已随 pause 保存),发音才开口,
  /// 避免旁白与单词发音两个声音叠在一起。尽力而为,失败不阻塞发音。
  Future<void> _pauseBookAudioIfPlaying() async {
    if (ref.read(audioPlayerProvider).playerState != PlayerState.playing) {
      return;
    }
    try {
      await ref.read(audioPlayerProvider.notifier).pause();
    } catch (_) {}
  }

  void _setupPlayerStateListener() {
    final player = _ttsPlayer;
    _playerStateSubscription?.cancel();
    _completeSubscription?.cancel();

    _playerStateSubscription = player.onPlayerStateChanged.listen((
      playerState,
    ) {
      debugPrint('TTS Player state changed: $playerState');
      if (playerState == PlayerState.completed) {
        debugPrint('TTS audio completed, resetting state');
        state = const SentenceTTSState();
      }
    });

    _completeSubscription = player.onPlayerComplete.listen((_) {
      debugPrint('TTS onPlayerComplete triggered');
      state = const SentenceTTSState();
    });
  }

  void _setupTTSServiceListener() {
    final ttsService = ref.read(ttsServiceProvider);
    _ttsServiceStateSubscription?.cancel();

    _ttsServiceStateSubscription = ttsService.playerStateStream.listen((
      playerState,
    ) {
      debugPrint('TTS Service state changed: $playerState');
      if (playerState == PlayerState.completed ||
          playerState == PlayerState.stopped) {
        debugPrint('TTS service finished, resetting state');
        state = const SentenceTTSState();
      }
    });
  }

  String _getUserFriendlyErrorMessage(String error) {
    if (error.contains('connection') || error.contains('connect')) {
      return 'Could not connect to TTS service. Please check your settings or network connection.';
    }
    if (error.contains('auth') ||
        error.contains('key') ||
        error.contains('401')) {
      return 'Invalid API key. Please check your TTS settings.';
    }
    if (error.contains('voice') || error.contains('No voices selected')) {
      return 'Please select a voice in TTS settings.';
    }
    if (error.contains('rate') || error.contains('quota')) {
      return 'TTS service quota exceeded. Please try again later.';
    }
    return 'TTS failed: $error';
  }

  /// 在发音专用播放器上播放 TTS 字节流。错误向上抛给调用方的
  /// try/catch(_handleError 统一处理重试)。
  Future<void> _playTtsBytes(BytesSource source) async {
    await _ttsPlayer.stop();
    await _ttsPlayer.play(source);
  }

  Future<void> speakSentence(String text, int sentenceId) async {
    final ttsService = ref.read(ttsServiceProvider);

    // 多词词元的文本带着零宽空格(on-device 引擎会读出停顿),入口剥掉,
    // 之后的状态、合成与重试用的都是同一份干净文本。
    text = normalizeTtsText(text);

    // 归一化后什么都不剩的句子不要去合成：`/tts/<lang>/` 的末段为空，服务端
    // 的 path 转换器要求至少一个字符，请求会 404 而不是返回音频。点读是单句
    // 行为，没有"推进下一句"可依赖，所以直接当作无事发生 —— 也不顺手暂停书籍
    // 音频，免得在页边空白上误点一下就掐掉正在播的有声书。网页播放器的
    // `speakText` 同样先判空再返回。
    if (text.isEmpty) return;

    try {
      // 点词瞬间就暂停书籍音频(位置随 pause 保存),不等网络合成:
      // 否则合成的一两秒里书还在走,发音出来时进度已经漂走。
      await _pauseBookAudioIfPlaying();

      state = state.copyWith(
        status: SentenceTTSStatus.loading,
        currentText: text,
        currentSentenceId: sentenceId,
        errorMessage: null,
        retryCount: 0,
        isFallenBackToNone: false,
        ttsAudioSource: null,
      );

      if (ttsService.supportsBytesOutput) {
        debugPrint('Fetching TTS audio bytes...');
        final audioBytes = await ttsService.getAudioBytes(text);
        debugPrint('Got ${audioBytes.length} bytes of audio');

        final bytesSource = BytesSource(audioBytes);

        state = state.copyWith(
          status: SentenceTTSStatus.playing,
          ttsAudioSource: bytesSource,
        );

        _setupPlayerStateListener();

        debugPrint('Starting TTS playback...');
        await _playTtsBytes(bytesSource);
        debugPrint('TTS playback started');
      } else {
        debugPrint('Using direct speak for on-device TTS...');
        _setupTTSServiceListener();
        await ref.read(ttsServiceProvider.notifier).ensureServiceReady();
        await ttsService.speak(text);
        state = state.copyWith(status: SentenceTTSStatus.playing);
      }
    } catch (e) {
      // Fragment that the server cannot synthesize (e.g. a single closing
      // bracket) -- not an error to surface or retry. Reset to idle so the
      // reader can move on to the next sentence.
      if (e is TTSUnpronounceableFragmentException) {
        debugPrint('Skipping unpronounceable TTS fragment: $text');
        state = const SentenceTTSState();
        return;
      }
      debugPrint('TTS Error: $e');
      await _handleError(text, sentenceId, e);
    }
  }

  Future<void> _handleError(String text, int sentenceId, dynamic error) async {
    final currentRetries = state.retryCount;

    if (currentRetries < maxRetries) {
      debugPrint('Retrying TTS (${currentRetries + 1}/$maxRetries)');
      state = state.copyWith(retryCount: currentRetries + 1);

      await Future.delayed(const Duration(seconds: 1));

      try {
        final ttsService = ref.read(ttsServiceProvider);

        if (ttsService.supportsBytesOutput) {
          final audioBytes = await ttsService.getAudioBytes(text);
          final bytesSource = BytesSource(audioBytes);

          state = state.copyWith(
            status: SentenceTTSStatus.playing,
            ttsAudioSource: bytesSource,
          );

          _setupPlayerStateListener();
          await _playTtsBytes(bytesSource);
        } else {
          debugPrint('Using direct speak for on-device TTS...');
          _setupTTSServiceListener();
          await ttsService.speak(text);
          state = state.copyWith(status: SentenceTTSStatus.playing);
        }
      } catch (retryError) {
        // Same handling as the outer catch: an unpronounceable fragment is
        // not retryable -- surface nothing, reset, done.
        if (retryError is TTSUnpronounceableFragmentException) {
          state = const SentenceTTSState();
          return;
        }
        await _handleError(text, sentenceId, retryError);
      }
    } else {
      final userFriendlyError = _getUserFriendlyErrorMessage(error.toString());
      state = state.copyWith(
        status: SentenceTTSStatus.error,
        errorMessage: userFriendlyError,
        retryCount: 0,
      );
    }
  }

  Future<void> stop() async {
    final ttsService = ref.read(ttsServiceProvider);

    try {
      debugPrint('Stopping TTS...');
      if (ttsService.supportsBytesOutput) {
        await _ttsPlayer.stop();
      } else {
        await ttsService.stop();
      }
      _ttsServiceStateSubscription?.cancel();
      state = const SentenceTTSState();
    } catch (e) {
      debugPrint('Failed to stop TTS: $e');
    }
  }

  Future<void> toggle(String text, int sentenceId) async {
    if (state.isPlaying) {
      await stop();
    } else {
      await speakSentence(text, sentenceId);
    }
  }

  void clearError() {
    state = state.copyWith(
      status: SentenceTTSStatus.idle,
      errorMessage: null,
      isFallenBackToNone: false,
    );
  }
}

final sentenceTTSProvider =
    NotifierProvider<SentenceTTSNotifier, SentenceTTSState>(() {
      return SentenceTTSNotifier();
    });
