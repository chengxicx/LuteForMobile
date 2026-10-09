import 'package:audioplayers_platform_interface/src/api/audio_context.dart';
import 'package:audioplayers_platform_interface/src/api/global_audio_event.dart';
import 'package:audioplayers_platform_interface/src/global_audioplayers_platform.dart';
import 'package:meta/meta.dart';

abstract class GlobalAudioplayersPlatformInterface
    implements
        MethodChannelGlobalAudioplayersPlatformInterface,
        EventChannelGlobalAudioplayersPlatformInterface {
  static GlobalAudioplayersPlatformInterface instance =
      GlobalAudioplayersPlatform();

  // 下面三个缓存 API 是 Android 专属（Media3 的磁盘缓存）。默认实现是**静默
  // 无操作**，而不是抛 —— Web 实现直接 extends 本类，而调用方（阅读页的预取
  // 与「离开页面就取消」）在非 Android 平台也会无条件调用，抛出去只会变成一堆
  // 没人接的异步异常。非 Android 上「不预取」本来就是正确行为。
  //
  // 注意这不掩盖 Android 上的错误：Android 走的是下面 mixin 里的真实实现，
  // 原生侧少了处理函数会得到 MissingPluginException，而不是这里返回的 false。

  @override
  Future<bool> fillAudioCache(
    String url, {
    Map<String, String>? headers,
    int? totalLength,
  }) async =>
      false;

  @override
  Future<int> exportAudioCache(String url, String destPath) async => 0;

  @override
  Future<void> cancelAudioCacheFill() async {}
}

abstract class MethodChannelGlobalAudioplayersPlatformInterface {
  /// Initializes the platform interface and disposes all existing players.
  ///
  /// This method is called when the plugin is first initialized
  /// and on every full restart.
  Future<void> init();

  Future<void> setGlobalAudioContext(AudioContext ctx);

  @visibleForTesting
  Future<void> emitGlobalLog(String message);

  @visibleForTesting
  Future<void> emitGlobalError(String code, String message);

  /// 把 [url] 整份补进播放器正在读的那份磁盘缓存。
  ///
  /// 关键在「同一份」：播放器只从这份缓存读，补全往这里写，所以整本书只走一次
  /// 网络。返回 `true` 表示补完，`false` 表示被后一次调用顶掉了（调用方应当当作
  /// 「取消」，不是失败）。
  ///
  /// [totalLength] 是调用方**已经探到的远端总长度**（调用方为了判断本地那份是否
  /// 完整本来就要探一次）。带上它能省掉原生侧重复探测的那一次请求，更要紧的是
  /// 让补全在拿到缓存锁之前不用先花一个网络往返 —— 否则播放器会抢在前面把开头
  /// 几 MB 从上游拉一遍。传 null 时原生侧自己探。
  ///
  /// 同一时刻只允许一条在跑。
  Future<bool> fillAudioCache(
    String url, {
    Map<String, String>? headers,
    int? totalLength,
  });

  /// 把已缓存的 [url] 导出成普通文件 [destPath]，返回字节数。
  ///
  /// 离线播放与影子跟读裁剪要的是真文件，而缓存内部是分片。调用方必须先
  /// [fillAudioCache] —— 这里只读缓存，不回源。
  Future<int> exportAudioCache(String url, String destPath);

  /// 掐掉正在跑的 [fillAudioCache]（换书、换页、离开阅读页）。
  ///
  /// 传输在原生侧，Dart 这边取消不了它 —— 不显式叫停的话，用户退出之后那
  /// 几十 MB 还会在后台默默下完。没有在跑的任务时是空操作。
  Future<void> cancelAudioCacheFill();
}

abstract class EventChannelGlobalAudioplayersPlatformInterface {
  Stream<GlobalAudioEvent> getGlobalEventStream();
}
