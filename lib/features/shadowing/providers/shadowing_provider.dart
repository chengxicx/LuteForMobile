import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/providers/network_providers.dart';
import '../../reader/providers/sentence_tts_provider.dart';
import '../models/shadowing_result.dart';
import '../models/shadowing_sentence.dart';

enum ShadowingPhase { idle, recording, processing, result, error }

/// Where the whisper model dropdown stands; mirrors the web reader's
/// `localStorage['shadowingModel']` (default small, remembered per device).
/// Cantonese is transcribed by the server's SenseVoice engine (independent
/// of this dropdown); whisper sizes here cover the remaining languages.
const List<String> kShadowingModelSizes = ['base', 'small', 'medium'];

@immutable
class ShadowingState {
  final ShadowingPhase phase;

  /// Seconds the running take has lasted -- the pulsing mic button's label.
  final int recordingSeconds;

  final ShadowingResult? result;

  /// Set when [phase] is [ShadowingPhase.error]; carries the category
  /// (whisper missing / no speech / server) plus the user-facing copy.
  final ShadowingException? error;

  final String modelSize;

  /// True once a finished take exists on disk -- gates the "play my
  /// recording" button (a fresh panel starts without one).
  final bool hasTake;

  /// True while the user's own recording is being played back.
  final bool playingRecording;

  /// True while a clipped piece of the book audio (the reference take) is
  /// playing.  TTS references are tracked by [sentenceTTSProvider] instead.
  final bool playingReference;

  /// Which slow phase the server's scoring task is in while
  /// [ShadowingPhase.processing] -- model load vs actual transcription.
  final ShadowingWaitPhase? waitPhase;

  /// Seconds elapsed since the scoring task started -- the wait label.
  final int waitSeconds;

  /// Furigana readings for the practised sentence's tokens, parallel to
  /// [ShadowingSentence.tokens].  Null until the server answers (or when
  /// the language has no readings): the panel then shows plain words.
  final List<ShadowingToken>? readings;

  /// copyWith 的「未传参」哨兵:与项目其他 Notifier 一致,让「传 null 表示
  /// 清空」和「没传」是两件事,否则错误提示一旦写上就清不掉。
  static const Object _unset = Object();

  const ShadowingState({
    this.phase = ShadowingPhase.idle,
    this.recordingSeconds = 0,
    this.result,
    this.error,
    this.modelSize = 'small',
    this.hasTake = false,
    this.playingRecording = false,
    this.playingReference = false,
    this.waitPhase,
    this.waitSeconds = 0,
    this.readings,
  });

  bool get isRecording => phase == ShadowingPhase.recording;
  bool get isProcessing => phase == ShadowingPhase.processing;
  bool get hasResult => result != null;

  ShadowingState copyWith({
    ShadowingPhase? phase,
    int? recordingSeconds,
    ShadowingResult? result,
    Object? error = _unset,
    String? modelSize,
    bool? hasTake,
    bool? playingRecording,
    bool? playingReference,
    Object? waitPhase = _unset,
    int? waitSeconds,
    Object? readings = _unset,
  }) {
    return ShadowingState(
      phase: phase ?? this.phase,
      recordingSeconds: recordingSeconds ?? this.recordingSeconds,
      result: result ?? this.result,
      error: error == _unset ? this.error : error as ShadowingException?,
      modelSize: modelSize ?? this.modelSize,
      hasTake: hasTake ?? this.hasTake,
      playingRecording: playingRecording ?? this.playingRecording,
      playingReference: playingReference ?? this.playingReference,
      waitPhase:
          waitPhase == _unset ? this.waitPhase : waitPhase as ShadowingWaitPhase?,
      waitSeconds: waitSeconds ?? this.waitSeconds,
      readings: readings == _unset
          ? this.readings
          : readings as List<ShadowingToken>?,
    );
  }
}

/// Drives one shadowing take: record (device mic) -> upload to the server's
/// `/read/shadowing/transcribe` -> hold the scored result for the panel.
///
/// Playback of the take and of the book-audio reference each get their own
/// [AudioPlayer] instance -- sharing either with the MP3 book player or the
/// TTS pronunciation player would clobber the source the other one has
/// loaded (the same reason [SentenceTTSNotifier] owns a dedicated player).
class ShadowingNotifier extends Notifier<ShadowingState> {
  @override
  ShadowingState build() {
    ref.onDispose(_disposeResources);
    _loadModelSize();
    return const ShadowingState();
  }

  static const _modelSizePrefKey = 'shadowing_model';

  /// 一次 take 的上限。跟读是逐句的,任何长句 60 秒都足够;不设上限的
  /// 录音只会把麦克风一直占着,而用户往往意识不到自己还在录。
  static const int maxRecordingSeconds = 60;

  /// 引擎单次调用的兜底时限。BOOX 的音频 HAL 偶发把**普通 PCM 采集**也
  /// 路由进 compress-offload 录音用例(audio-record-compress2),而它要
  /// 打开的 /dev/snd/comprC0D36 在内核侧根本不存在——输入流在
  /// start/standby 里无限横跳、一帧都出不来,引擎的 stop() 等 finalize
  /// 就永远等不到,Dart 侧的 await 随之挂死(2026-10-03 Leaf5C 实测:
  /// 面板停在 Recording、系统栏麦克风常亮,所有经过 stop() 的路径全部
  /// 卡死)。所以每个引擎调用都套超时;超时即整个 recorder 实例作废
  /// (_abandonRecorder),面板回到可用状态并交代清楚。
  static const Duration _engineCallTimeout = Duration(seconds: 5);

  /// 无声看门狗的判定线:插件在零帧时报告的振幅正好是地板值
  /// (-160 dBFS)。真麦克风哪怕在寂静房间也有自噪声,不会贴地;贴地
  /// 只可能是采集零帧(HAL 横跳)。
  static const double _amplitudeFloorDb = -160.0;

  /// 看门狗的检查点(开口第 3、8 秒各查一次,减少误伤)。
  static const Set<int> _silentCheckSeconds = {3, 8};

  AudioRecorder? _recorder;
  Timer? _recordingTimer;

  AudioPlayer? _takePlayer;
  StreamSubscription<void>? _takeCompleteSubscription;
  StreamSubscription<Duration>? _referencePositionSubscription;

  AudioPlayer? _referencePlayer;

  /// 已完成的 take 的本地文件(回放、清理用)。每次新录音覆盖旧文件路径。
  String? _lastTakePath;

  void _loadModelSize() {
    // 选择器已从面板移除(与 web 一致):SenseVoice 转写 zh/yue/en/ja/ko,
    // 这个值只影响 whisper 兜底的语言。遗留偏好仍生效并随请求发送。
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_modelSizePrefKey);
      if (saved != null && kShadowingModelSizes.contains(saved)) {
        state = state.copyWith(modelSize: saved);
      }
    });
  }

  Future<void> setModelSize(String size) async {
    if (!kShadowingModelSizes.contains(size)) return;
    state = state.copyWith(modelSize: size);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelSizePrefKey, size);
  }

  /// Which sentence the in-flight readings request belongs to; a late
  /// answer for a sentence the user already navigated away from is
  /// dropped rather than painted over the new one.
  int? _readingsSentenceId;

  /// Fetch the practised sentence's furigana readings.  Best-effort:
  /// nothing is shown when the server has none to give.
  ///
  /// The whole sentence goes along as `full_text` so the server reads each
  /// morpheme in context (一つ -> ひとつ, not いち + つ); [displayText] is
  /// the sentence as rendered, punctuation included, which is exactly the
  /// text the server needs to parse.
  Future<void> loadReadings(ShadowingSentence sentence) async {
    final languageId = sentence.languageId;
    if (languageId == null || sentence.tokens.isEmpty) return;
    _readingsSentenceId = sentence.sentenceId;
    final readings = await ref
        .read(contentServiceProvider)
        .fetchShadowingReadings(
          languageId: languageId,
          tokens: sentence.tokens,
          fullText: sentence.displayText,
        );
    if (readings.isEmpty || sentence.sentenceId != _readingsSentenceId) return;
    state = state.copyWith(readings: readings);
  }

  AudioRecorder get _recorderInstance {
    final existing = _recorder;
    if (existing != null) return existing;
    final recorder = AudioRecorder();
    _recorder = recorder;
    return recorder;
  }

  /// 录音引擎挂死后的断舍离:实例整个作废(dispose 也可能挂,同样套
  /// 超时,超时就随它去——它持有的系统资源随进程退出回收),下次
  /// start() 用全新实例;挂死 take 的半成品文件一并清掉。麦克风仍被
  /// 僵尸流占着时,重启 App 才能真正释放,错误文案会交代这一点。
  void _abandonRecorder([AudioRecorder? instance]) {
    final recorder = instance ?? _recorder;
    _recorder = null;
    if (recorder == null) return;
    unawaited(
      recorder.dispose().timeout(_engineCallTimeout, onTimeout: () {}),
    );
    final path = _lastTakePath;
    _lastTakePath = null;
    if (path != null) {
      unawaited(File(path).delete().then((_) {}, onError: (_) {}));
    }
  }

  /// 采集零帧的看门狗:开口后振幅仍贴地,说明 HAL 又横跳了,这通 take
  /// 注定无声。与其让用户对着 "Recording…" 白读、再卡在 stop 上,不如
  /// 当场收口交代。查不到振幅(调用本身也挂了)就放着不管,超时与
  /// 停止路径各自有兜底。
  Future<void> _abortIfSilent(AudioRecorder recorder) async {
    if (!state.isRecording) return;
    double amplitude;
    try {
      amplitude =
          (await recorder.getAmplitude().timeout(_engineCallTimeout)).current;
    } catch (_) {
      return;
    }
    if (amplitude > _amplitudeFloorDb || !state.isRecording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _abandonRecorder(recorder);
    state = state.copyWith(
      phase: ShadowingPhase.error,
      recordingSeconds: 0,
      error: const ShadowingException(
        ShadowingErrorKind.serverError,
        'The microphone delivered no audio (device audio glitch). '
        'Restart the app, then take again.',
      ),
    );
  }

  AudioPlayer get _takePlayerInstance {
    final existing = _takePlayer;
    if (existing != null) return existing;
    final player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _takeCompleteSubscription = player.onPlayerComplete.listen((_) {
      state = state.copyWith(playingRecording: false);
    });
    _takePlayer = player;
    return player;
  }

  AudioPlayer get _referencePlayerInstance {
    final existing = _referencePlayer;
    if (existing != null) return existing;
    final player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _referencePlayer = player;
    return player;
  }

  /// 开始或结束一次录音。结束即自动上传打分(与 Web 版一次点击一个动作
  /// 不同,这里两次点击之间没有别的 UI 状态,合并成一个切换更顺手)。
  Future<void> toggleRecording(ShadowingSentence sentence) async {
    if (state.isRecording) {
      await _stopAndScore(sentence);
    } else {
      await _startRecording(sentence);
    }
  }

  Future<void> _startRecording(ShadowingSentence sentence) async {
    // 有结果/错误挂着时重录:先把面板回到干净的录音态(模型选择与
    // 原句假名保留 —— 它们不属于某一次 take)。
    _referencePositionSubscription?.cancel();
    state = ShadowingState(
      modelSize: state.modelSize,
      readings: state.readings,
    );

    try {
      // 每次开口前都真问一遍(而不是缓存 provider 的结论):拒绝过、去系统
      // 设置里打开后回来,这次请求就能直接拿到 granted。
      final status = await Permission.microphone.request();
      if (!(status.isGranted || status.isLimited)) {
        state = state.copyWith(
          phase: ShadowingPhase.error,
          error: const ShadowingException(
            ShadowingErrorKind.permissionDenied,
            'Microphone permission is required for shadowing. Enable it in the app settings.',
          ),
        );
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final shadowingDir = Directory('${tempDir.path}/shadowing');
      await shadowingDir.create(recursive: true);
      // 旧 take 留着不如直接覆盖:文件只有几秒大,回放永远只听最新一遍。
      final path =
          '${shadowingDir.path}/shadowing_take_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _lastTakePath = path;

      // AAC-LC 48kHz 单声道 + voiceRecognition 音源,体积与旧配置相同
      // (48kbps ≈ 6KB/s,60s 上限约 360KB)。
      //
      // 唯一与旧配置的实质差异是采样率与音源,都冲着 Leaf5C 的音频 HAL:
      // 16k 的普通采集偶尔会被路由进 compress-offload 录音用例
      // (audio-record-compress2),而它要打开的 /dev/snd/comprC0D36 在
      // 内核侧根本不存在——输入流 start/standby 无限横跳、一帧不出,
      // 引擎的 stop() 由此挂死(2026-10-03 实测,面板停在 Recording、
      // 系统栏麦克风常亮)。48k 是 HAL 的原生采样率,不走压缩采集的
      // 低采样率偏好;voiceRecognition 音源 + 显式关掉回声消除/噪声
      // 抑制,既绕开 Fluence 前置处理的路由,也不再给转写染色。
      // record 7.x 里无论 AAC 还是 WAV,采集都是 AudioRecord PCM,文件
      // 格式本身不参与路由,体积小的 AAC 没有理由换掉。服务器侧解码后
      // 本来就统一重采样到 16k,采样率的提升不增加任何服务器改动。
      //
      // 即便如此,挂死仍可能发生(超时+看门狗兜底,见 _engineCallTimeout);
      // start 也可能挂死(HAL 被上一条僵尸流占着):同样超时作废。
      final recorder = _recorderInstance;
      try {
        await recorder
            .start(
              const RecordConfig(
                encoder: AudioEncoder.aacLc,
                sampleRate: 48000,
                numChannels: 1,
                bitRate: 48000,
                echoCancel: false,
                noiseSuppress: false,
                androidConfig: AndroidRecordConfig(
                  audioSource: AndroidAudioSource.voiceRecognition,
                ),
              ),
              path: path,
            )
            .timeout(_engineCallTimeout);
      } on TimeoutException {
        _abandonRecorder(recorder);
        state = state.copyWith(
          phase: ShadowingPhase.error,
          error: const ShadowingException(
            ShadowingErrorKind.serverError,
            'The recorder did not start (device audio is stuck). '
            'Restart the app, then take again.',
          ),
        );
        return;
      }

      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        final next = state.recordingSeconds + 1;
        if (next >= maxRecordingSeconds) {
          // 到上限自动收口打分,录音不该无限走下去。
          await _stopAndScore(sentence);
          return;
        }
        state = state.copyWith(recordingSeconds: next);
        if (_silentCheckSeconds.contains(next)) {
          await _abortIfSilent(recorder);
        }
      });

      state = state.copyWith(phase: ShadowingPhase.recording);
    } on ShadowingException catch (e) {
      state = state.copyWith(phase: ShadowingPhase.error, error: e);
    } catch (e) {
      state = state.copyWith(
        phase: ShadowingPhase.error,
        error: ShadowingException(ShadowingErrorKind.serverError, '$e'),
      );
    }
  }

  Future<void> _stopAndScore(ShadowingSentence sentence) async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    String? path;
    var engineStuck = false;
    // 先把面板拨到 processing:stop() 若在 HAL 上挂死,超时+兜底要几秒才
    // 落地,面板不能还停在 "Recording…" 让用户以为没点上。
    state = state.copyWith(phase: ShadowingPhase.processing);
    try {
      path = await _recorderInstance.stop().timeout(_engineCallTimeout);
    } on TimeoutException {
      // 引擎挂死(见 _engineCallTimeout 的说明):实例作废,take 无法
      // finalize,只能整条放弃并交代。
      engineStuck = true;
      _abandonRecorder();
    } catch (e) {
      debugPrint('Shadowing: recorder.stop() failed: $e');
    }
    if (engineStuck) {
      state = state.copyWith(
        phase: ShadowingPhase.error,
        recordingSeconds: 0,
        error: const ShadowingException(
          ShadowingErrorKind.serverError,
          'The recorder stopped responding (device audio glitch). '
          'If recording keeps failing, restart the app.',
        ),
      );
      return;
    }
    if (path == null) {
      // stop() 拿不到文件时无从打分:回 idle,面板按钮恢复可按。
      state = state.copyWith(
        phase: ShadowingPhase.idle,
        error: const ShadowingException(
          ShadowingErrorKind.serverError,
          'Recording was not saved -- try again.',
        ),
      );
      return;
    }
    state = state.copyWith(hasTake: true);

    state = state.copyWith(phase: ShadowingPhase.processing);

    final languageId = sentence.languageId;
    if (languageId == null) {
      state = state.copyWith(
        phase: ShadowingPhase.error,
        error: const ShadowingException(
          ShadowingErrorKind.serverError,
          'This page does not carry a language -- shadowing needs one to score against.',
        ),
      );
      return;
    }

    try {
      final service = ref.read(contentServiceProvider);
      final result = await service.transcribeShadowing(
        audioPath: path,
        languageId: languageId,
        tokens: sentence.tokens,
        fullText: sentence.displayText,
        model: state.modelSize,
        onWait: (phase, seconds) {
          state = state.copyWith(waitPhase: phase, waitSeconds: seconds);
        },
      );
      state = state.copyWith(
        phase: ShadowingPhase.result,
        result: result,
        error: null,
        recordingSeconds: 0,
        hasTake: true,
        waitPhase: null,
        waitSeconds: 0,
      );
    } on ShadowingException catch (e) {
      // 打分失败,但 take 本身录上了,回放按钮保留。
      state = state.copyWith(
        phase: ShadowingPhase.error,
        error: e,
        recordingSeconds: 0,
        hasTake: true,
        waitPhase: null,
        waitSeconds: 0,
      );
    } catch (e) {
      state = state.copyWith(
        phase: ShadowingPhase.error,
        error: ShadowingException(ShadowingErrorKind.serverError, '$e'),
        recordingSeconds: 0,
        hasTake: true,
        waitPhase: null,
        waitSeconds: 0,
      );
    }
  }

  /// Play back the user's own take.  Only valid once a take exists; the
  /// panel keeps the button hidden until then.
  Future<void> playRecording() async {
    final path = _lastTakePath;
    if (path == null) return;
    try {
      // 两个回放源互斥:听自己的录音时停掉参考播放,反之亦然。
      await _stopReference();
      final player = _takePlayerInstance;
      await player.stop();
      await player.play(DeviceFileSource(path));
      state = state.copyWith(playingRecording: true);
    } catch (e) {
      debugPrint('Shadowing: take playback failed: $e');
      state = state.copyWith(playingRecording: false);
    }
  }

  Future<void> stopRecordingPlayback() async {
    try {
      await _takePlayer?.stop();
    } catch (_) {}
    state = state.copyWith(playingRecording: false);
  }

  /// Play the reference: a clipped piece of the book's own audio for media
  /// books, a TTS reading of the sentence for text books (the latter is
  /// fully handled by the sentence TTS machinery, state included).
  Future<void> playReference(ShadowingSentence sentence) async {
    // 三个声音源互斥:参考开播前把自己家里的其余两个都停掉。
    await stopRecordingPlayback();
    await _stopReference();
    try {
      await ref.read(sentenceTTSProvider.notifier).stop();
    } catch (_) {}

    if (sentence.hasClip) {
      await _playClip(sentence);
      return;
    }
    await ref
        .read(sentenceTTSProvider.notifier)
        .speakSentence(sentence.displayText, sentence.sentenceId);
  }

  Future<void> _playClip(ShadowingSentence sentence) async {
    try {
      final player = _referencePlayerInstance;
      await player.stop();
      await player.setSourceDeviceFile(sentence.clipPath!);
      final start =
          Duration(milliseconds: (sentence.clipStart! * 1000).round());
      await player.seek(start);
      await player.resume();

      // 裁剪段没有自然的「播完」事件(文件在句尾之后还有内容),到 cue 末
      // 就收手,不然原曲一直走,听的人不知道该开口跟读了。
      final end = Duration(milliseconds: (sentence.clipEnd! * 1000).round());
      _referencePositionSubscription?.cancel();
      _referencePositionSubscription = player.onPositionChanged.listen((
        position,
      ) {
        if (position >= end) {
          _stopReference();
        }
      });

      state = state.copyWith(playingReference: true);
    } catch (e) {
      debugPrint('Shadowing: reference clip playback failed: $e');
      state = state.copyWith(playingReference: false);
    }
  }

  Future<void> stopReference() => _stopReference();

  Future<void> _stopReference() async {
    _referencePositionSubscription?.cancel();
    _referencePositionSubscription = null;
    try {
      await _referencePlayer?.stop();
    } catch (_) {}
    if (state.playingReference) {
      state = state.copyWith(playingReference: false);
    }
  }

  /// 面板关闭或换句时调用:录音、两个回放源、TTS 全停,状态清回出厂
  /// (模型选择保留)。录音文件刻意不删:面板可能马上重开,回放上一遍
  /// take 仍有用;几秒的 m4a 不足挂齿,系统清理缓存目录时一并带走。
  Future<void> reset() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _readingsSentenceId = null;
    if (state.isRecording) {
      try {
        await _recorderInstance.stop().timeout(_engineCallTimeout);
      } on TimeoutException {
        _abandonRecorder();
      } catch (_) {}
    }
    await stopRecordingPlayback();
    await _stopReference();
    try {
      await ref.read(sentenceTTSProvider.notifier).stop();
    } catch (_) {}
    state = ShadowingState(
      modelSize: state.modelSize,
    );
  }

  Future<void> _disposeResources() async {
    _recordingTimer?.cancel();
    _referencePositionSubscription?.cancel();
    _takeCompleteSubscription?.cancel();
    try {
      await _recorder?.dispose().timeout(_engineCallTimeout);
    } on TimeoutException {
      // 挂死的引擎不再等待,资源随进程回收。
      _recorder = null;
    } catch (_) {}
    try {
      await _takePlayer?.dispose();
    } catch (_) {}
    try {
      await _referencePlayer?.dispose();
    } catch (_) {}
    // dispose 是异步清理的最后时机,临时 take 文件不再有回放者,删掉。
    final path = _lastTakePath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }  }
}

final shadowingProvider =
    NotifierProvider<ShadowingNotifier, ShadowingState>(() {
  return ShadowingNotifier();
});
