import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/core/network/tts_service.dart';
import 'package:song_mobile/core/providers/tts_provider.dart';
import 'package:song_mobile/features/settings/providers/tts_settings_provider.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';
import '../providers/audio_player_provider.dart';
import '../providers/current_book_provider.dart';
import 'tts_player_provider.dart';

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

  /// copyWith 的「未传参」哨兵：`errorMessage ?? this.errorMessage` 会让
  /// 「传 null 表示清空」和「没传」变成同一件事，错误提示一旦写上就清不掉。
  static const Object _unset = Object();

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
    Object? errorMessage = _unset,
    String? currentText,
    int? currentSentenceId,
    int? retryCount,
    bool? isFallenBackToNone,
    BytesSource? ttsAudioSource,
  }) {
    return SentenceTTSState(
      status: status ?? this.status,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
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
      _onDeviceFallback?.dispose();
      _onDeviceFallback = null;
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

  /// 离线本地兜底引擎，懒建。当前 TTS provider 是服务器型的（Edge TTS）
  /// 而服务器不可达时，发音落到它身上，而不是等一个注定超时的请求再重试
  /// 三轮 —— 那是「地铁里点词没声音」的直接原因。
  OnDeviceTTSService? _onDeviceFallback;

  /// 本轮发音实际使用的服务。stop() 要按它停：兜底引擎不在
  /// [ttsServiceProvider] 里，光停主服务停不掉它。
  TTSService? _activeService;

  /// 发音真正使用的服务：主服务；主服务是服务器型的 Edge TTS 且服务端
  /// 不可达时，改用本地兜底引擎。其他 provider（Kokoro/OpenAI/…）不是
  /// Song 服务器的依赖，离线与否由各自的端点决定，不在这里插手。
  TTSService _resolveTTSService() {
    final primary = ref.read(ttsServiceProvider);
    if (primary is EdgeTTSService && !ServerStatusManager.isReachable) {
      debugPrint('TTS: server unreachable, falling back to on-device engine');
      return _fallbackOnDeviceService();
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

  /// 兜底引擎开口前的装配：设置页 on-device 配置（语速/音调/音量，默认
  /// 0.5 = Android 正常速度 —— 裸引擎的出厂默认在设备上体感太快，且设置
  /// 滑块对它不生效）+ 当前书的语言。与整页朗读播放器共用同一套装配
  /// （[prepareOnDeviceFallback]）。
  Future<void> _prepareFallbackService() async {
    final fallback = _onDeviceFallback;
    if (fallback == null) return;
    await prepareOnDeviceFallback(
      fallback,
      config: onDeviceConfigForFallback(ref.read(ttsSettingsProvider)),
      bookLanguageName: ref.read(currentBookProvider).languageName,
    );
  }

  /// 解析服务并完成一次「合成 + 开口」。初始尝试与每一轮重试都走这里：
  /// 每次都重新解析，服务器中途断线时，下一轮重试自然落到本地兜底；
  /// 网络恢复时也会自然回到服务器。
  Future<void> _synthesizeAndPlay(String text) async {
    final service = _resolveTTSService();
    _activeService = service;
    final isPrimary = identical(service, ref.read(ttsServiceProvider));

    if (isPrimary) {
      // 点词发音用的是同一份 Edge 服务，语言也得现推一次：只在「服务创建
      // 那一刻」定语言，会在书语言解析晚到（或曾经失败）时把日文词发去英文
      // 语音 —— 实测就是 `/tts/en/あじ` 这类请求，服务端一律 422。
      await ref.read(ttsServiceProvider.notifier).syncEdgeLanguage();
    }

    if (service.supportsBytesOutput) {
      debugPrint('Fetching TTS audio bytes...');
      final audioBytes = await service.getAudioBytes(text);
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
      _listenServiceCompletion(service);
      if (isPrimary) {
        await ref.read(ttsServiceProvider.notifier).ensureServiceReady();
      } else {
        await _prepareFallbackService();
      }
      await service.speak(text);
      state = state.copyWith(status: SentenceTTSStatus.playing);
    }
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

  /// 整页朗读在播时先暂停它。
  ///
  /// 两条链路共用同一个 on-device 引擎实例（flutter_tts 的默认队列模式是
  /// QUEUE_FLUSH）：朗读念到一半被点词发音插进来，那一句会被直接冲掉，而
  /// 引擎随后报出的完成事件又会被整页朗读当成「这句读完了」—— 高亮从此跑到
  /// 音频前面，越走越乱（用户看到的「不是同一句」+「跳着走」）。
  /// 发音前先把它停下来，最省事也最不意外。
  Future<void> _pauseReadAloudIfPlaying() async {
    try {
      final player = ref.read(ttsPlayerProvider);
      if (!player.isPlaying && !player.isLoading) return;
      await ref.read(ttsPlayerProvider.notifier).pause();
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

  /// 监听指定服务实例的完成事件 —— 兜底引擎不在 [ttsServiceProvider] 里，
  /// 完成事件要从它自己的流上收。
  void _listenServiceCompletion(TTSService service) {
    _ttsServiceStateSubscription?.cancel();

    _ttsServiceStateSubscription = service.playerStateStream.listen((
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
      // 整页朗读也先停下：两个链路共用同一个 on-device 引擎实例，让它一边
      // 念一边被点词发音插话，只会把「哪一句读完了」这件事彻底搞乱。
      await _pauseReadAloudIfPlaying();

      state = state.copyWith(
        status: SentenceTTSStatus.loading,
        currentText: text,
        currentSentenceId: sentenceId,
        errorMessage: null,
        retryCount: 0,
        isFallenBackToNone: false,
        ttsAudioSource: null,
      );

      await _synthesizeAndPlay(text);
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
        // 重新解析服务：断网瞬间主服务的请求失败后，可达性标志已被拦截器
        // 置假，这里自然落到本地兜底；网络恢复时同样自然回到服务器。
        await _synthesizeAndPlay(text);
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
    try {
      debugPrint('Stopping TTS...');
      final primary = ref.read(ttsServiceProvider);
      // 本轮发音若走的是本地兜底实例，得停它本身 —— 它不在
      // [ttsServiceProvider] 里，停主服务停不掉它。
      final active = _activeService;
      if (active != null && !identical(active, primary)) {
        await active.stop();
      } else if (primary.supportsBytesOutput) {
        await _ttsPlayer.stop();
      } else {
        await primary.stop();
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
