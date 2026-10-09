import 'dart:async';

import 'package:audioplayers/src/audio_logger.dart';
import 'package:audioplayers/src/uri_ext.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';

GlobalAudioplayersPlatformInterface? _lastGlobalAudioplayersPlatform;

/// Handle global audio scope like calls and events concerning all AudioPlayers.
class GlobalAudioScope {
  Completer<void>? _initCompleter;

  GlobalAudioplayersPlatformInterface get _platform =>
      GlobalAudioplayersPlatformInterface.instance;

  /// Stream of global events.
  late final Stream<GlobalAudioEvent> eventStream;

  /// Stream of global log events.
  Stream<String> get onLog => eventStream
      .where((event) => event.eventType == GlobalAudioEventType.log)
      .map((event) => event.logMessage!);

  GlobalAudioScope() {
    eventStream = _platform.getGlobalEventStream();
    onLog.listen(
      AudioLogger.log,
      onError: AudioLogger.error,
    );
  }

  /// Ensure the global platform is initialized.
  Future<void> ensureInitialized() async {
    if (_lastGlobalAudioplayersPlatform != _platform) {
      // This will clear all open players on the platform when a full restart is
      // performed.
      _lastGlobalAudioplayersPlatform = _platform;
      _initCompleter = Completer<void>();
      try {
        await _platform.init();
        _initCompleter?.complete();
      } on Exception catch (e, stackTrace) {
        _initCompleter?.completeError(e, stackTrace);
      }
    }
    await _initCompleter?.future;
  }

  Future<void> setAudioContext(AudioContext ctx) async {
    await ensureInitialized();
    await _platform.setGlobalAudioContext(ctx);
  }

  /// 把 [url] 整份补进播放器共用的磁盘缓存（Android / Media3）。
  ///
  /// 与 [AudioPlayer] 读的是同一份缓存：播放器只读、补全只写，所以一次传输既
  /// 起播又攒出离线文件。返回 `true` 补完、`false` 被后一次调用顶掉。
  ///
  /// 编码方式与 [AudioPlayer.setSourceUrl] 一致：**缓存键就是 URL 字符串**，
  /// 两边只要有一个字节不同，补全就会在缓存里另开一份，等于白干。
  ///
  /// [totalLength] 传调用方已探到的远端总长度（见平台接口的说明），省掉原生侧
  /// 重复探测，也让补全能抢在播放器前面拿到缓存锁。
  Future<bool> fillAudioCache(
    String url, {
    Map<String, String>? headers,
    int? totalLength,
  }) async {
    await ensureInitialized();
    return _platform.fillAudioCache(
      UriCoder.encodeOnce(url),
      headers: headers,
      totalLength: totalLength,
    );
  }

  /// 把已缓存的 [url] 导出成普通文件 [destPath]，返回字节数。
  ///
  /// 调用方负责先 [fillAudioCache]：这一步只读缓存，缺的部分不会回源。
  Future<int> exportAudioCache(String url, String destPath) async {
    await ensureInitialized();
    return _platform.exportAudioCache(UriCoder.encodeOnce(url), destPath);
  }

  /// 掐掉正在跑的 [fillAudioCache]（换书、换页、离开阅读页）。
  ///
  /// 没有在跑的任务时是空操作；非 Android 平台也是空操作。
  Future<void> cancelAudioCacheFill() async {
    await ensureInitialized();
    await _platform.cancelAudioCacheFill();
  }
}
