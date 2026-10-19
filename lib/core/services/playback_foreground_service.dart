import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 让 Android 在锁屏 / 切后台后继续出声：`mediaPlayback` 前台服务的 Dart 端。
///
/// 它**不接管音频** —— 声音仍由 audioplayers（Media3）和 flutter_tts 播放，
/// 这里只做一件事：在播放期间把 App 挂成前台服务，免得锁屏后进程被系统划进
/// cached 桶、CPU 进 suspend、Doze 掐网络，音频跟着断掉。
///
/// 服务全局只有一份，而 MP3（有声书）与整页朗读 TTS 是两条互相独立的链路，
/// 所以持有者记成集合而不是计数器：
///
/// * `acquire` / `release` 用同一个 holder 反复调用是幂等的 —— `play()` 每次
///   起播都会调一次，不该把服务"叠"起来。
/// * 只有**最后一个**持有者释放时才真的停服务：TTS 先停、MP3 还在播时，
///   通知和前台资格必须留着。
class PlaybackForegroundService {
  PlaybackForegroundService._();

  /// 有声书播放器（`audioPlayerProvider`）的持有者标识。
  static const String mp3 = 'mp3';

  /// 整页朗读播放器（`ttsPlayerProvider`）的持有者标识。
  static const String tts = 'tts';

  static const MethodChannel _channel = MethodChannel(
    'com.schlick7.luteformobile/media_playback',
  );

  static final Set<String> _holders = <String>{};

  /// 通道只在 Android 上存在（见 MediaPlaybackBridge.kt）。桌面 / web / iOS
  /// 直接返回，调用方不必自己判断平台。
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> acquire(String holder) async {
    if (!_supported) return;
    final wasEmpty = _holders.isEmpty;
    _holders.add(holder);
    if (!wasEmpty) return;
    await _invoke('start');
  }

  static Future<void> release(String holder) async {
    if (!_supported) return;
    final removed = _holders.remove(holder);
    if (!removed || _holders.isNotEmpty) return;
    await _invoke('stop');
  }

  /// 兜底清空：退出阅读页 / App 被销毁时调，不依赖各链路自己善后。
  /// 集合还没清干净就以为"只有自己"，所以先清空再停。
  static Future<void> releaseAll() async {
    if (!_supported || _holders.isEmpty) return;
    _holders.clear();
    await _invoke('stop');
  }

  /// 仅测试用：重置内部状态。
  @visibleForTesting
  static void resetForTest() {
    _holders.clear();
  }

  @visibleForTesting
  static Set<String> get holdersForTest => Set.unmodifiable(_holders);

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<bool>(method);
    } on MissingPluginException {
      // 通道没注册（桌面构建、单测环境）：静默失败，不影响播放。
    } catch (e) {
      // Android 12+ 拒绝后台启动前台服务时会走到这里。播放本身能继续，
      // 只是锁屏后可能被系统掐掉，不值得把异常抛给播放链路。
      debugPrint('PlaybackForegroundService.$method failed: $e');
    }
  }
}
