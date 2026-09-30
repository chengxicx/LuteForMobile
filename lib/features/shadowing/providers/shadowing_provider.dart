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

  /// Model sizes that are already on the server (downloaded and cached).
  /// Null until the first lookup lands, or when the server could not be
  /// asked (fall back to offering every size).
  final List<String>? cachedModels;

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
    this.cachedModels,
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
    List<String>? cachedModels,
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
      cachedModels: cachedModels ?? this.cachedModels,
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
    _loadCachedModels();
    return const ShadowingState();
  }

  static const _modelSizePrefKey = 'shadowing_model';

  /// 一次 take 的上限。跟读是逐句的,任何长句 60 秒都足够;不设上限的
  /// 录音只会把麦克风一直占着,而用户往往意识不到自己还在录。
  static const int maxRecordingSeconds = 60;

  /// 正在录的句子 —— 计时到上限自动收口时要用它打分(回调里拿不到
  /// 点击时的那个参数)。
  ShadowingSentence? _activeSentence;

  AudioRecorder? _recorder;
  Timer? _recordingTimer;

  AudioPlayer? _takePlayer;
  StreamSubscription<void>? _takeCompleteSubscription;
  StreamSubscription<Duration>? _referencePositionSubscription;

  AudioPlayer? _referencePlayer;

  /// 已完成的 take 的本地文件(回放、清理用)。每次新录音覆盖旧文件路径。
  String? _lastTakePath;

  void _loadModelSize() {
    // SharedPreferences 读取是异步的,但值只影响下拉框初值,晚一拍无妨。
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

  /// Asks the server which whisper sizes are already downloaded.  Once at
  /// least one size is cached, the picker narrows to those: picking a
  /// never-downloaded size would silently trigger a multi-hundred-MB
  /// download on the server, which is not a decision a dropdown tap
  /// should make.  When nothing is cached yet that first download is
  /// unavoidable, so every size stays offered.  A saved modelSize that
  /// is not cached is re-pointed to the first cached size.
  Future<void> _loadCachedModels() async {
    final info = await ref.read(contentServiceProvider).fetchWhisperModels();
    final models = info?['models'];
    if (models is! List) return;
    final cached = kShadowingModelSizes
        .where(
          (size) => models.any(
            (m) => m is Map && m['size'] == size && m['cached'] == true,
          ),
        )
        .toList();
    if (cached.isEmpty) return;
    state = state.copyWith(cachedModels: cached);
    if (!cached.contains(state.modelSize)) {
      await setModelSize(cached.first);
    }
  }

  AudioRecorder get _recorderInstance {
    final existing = _recorder;
    if (existing != null) return existing;
    final recorder = AudioRecorder();
    _recorder = recorder;
    return recorder;
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
    // 有结果/错误挂着时重录:先把面板回到干净的录音态(模型选择保留)。
    _referencePositionSubscription?.cancel();
    state = ShadowingState(
      modelSize: state.modelSize,
      cachedModels: state.cachedModels,
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

      // record 5.x 的 start() 返回 void:起不来的情况(输入被占用等)以
      // 异常形态出现,由下面的 catch 统一兜住,没有 bool 可查。
      //
      // 编码 AAC-LC、16kHz:跟读只管语音,16k 对转写无损失(whisper 就以
      // 16kHz 训练),5 秒的 take 只有约 20KB;非标准采样率也基本不会落进
      // BOOX 音频 HAL 的 compress-offload 录音路径(44.1k AAC 在它上面
      // 出现过 start/standby 反复横跳)。真机上若再遇到录音异常,退回
      // AudioEncoder.wav 是一行的事(PCM 直通,兼容性最好,但体积大十倍)。
      await _recorderInstance.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 48000,
        ),
        path: path,
      );

      _recordingTimer?.cancel();
      _activeSentence = sentence;
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        final next = state.recordingSeconds + 1;
        if (next >= maxRecordingSeconds) {
          // 到上限自动收口打分,录音不该无限走下去。
          await _stopAndScore(sentence);
          return;
        }
        state = state.copyWith(recordingSeconds: next);
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
    try {
      path = await _recorderInstance.stop();
    } catch (e) {
      debugPrint('Shadowing: recorder.stop() failed: $e');
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
    if (state.isRecording) {
      try {
        await _recorderInstance.stop();
      } catch (_) {}
    }
    await stopRecordingPlayback();
    await _stopReference();
    try {
      await ref.read(sentenceTTSProvider.notifier).stop();
    } catch (_) {}
    state = ShadowingState(
      modelSize: state.modelSize,
      cachedModels: state.cachedModels,
    );
  }

  Future<void> _disposeResources() async {
    _recordingTimer?.cancel();
    _referencePositionSubscription?.cancel();
    _takeCompleteSubscription?.cancel();
    try {
      await _recorder?.dispose();
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
