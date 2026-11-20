import 'package:flutter/foundation.dart';

/// 服务器上 lute-picwords 插件的可用性。
///
/// 分得比「有 / 没有」细，是因为三种「没有」的处置完全不同：
///  * [notInstalled]：服务器**确实**没装这个插件 —— 确定性结论，入口整个藏掉；
///  * [loginRequired] / [unreachable] / [serverError]：**现在问不到** ——
///    都是可自愈的（重新登录、恢复网络、服务端修好），藏掉会让功能凭空
///    消失且无法重试，所以显示成禁用卡 + 原因 + Retry。
enum PicWordsAvailability {
  /// 还没探测过。
  unknown,

  /// 请求在飞。
  checking,

  /// 插件在，可以进入。
  available,

  /// 404：蓝图没注册，服务器没装这个插件。
  notInstalled,

  /// 被 302 到 /login：多用户会话缺失或过期。
  loginRequired,

  /// 连接失败（断网、服务器不可达）。
  unreachable,

  /// 其他 4xx/5xx 或未知异常。
  serverError,
}

@immutable
class PicWordsState {
  final PicWordsAvailability availability;

  /// 禁用卡上给用户看的一句话原因（可用/没装时为 null）。
  final String? message;

  /// 这个结论属于哪个 serverUrl。
  ///
  /// 用户在设置里换了服务器后，旧结论必须作废 —— 否则会把「新服务器装了
  /// 插件」判成没装，入口永远不出现。
  final String serverUrl;

  const PicWordsState({
    this.availability = PicWordsAvailability.unknown,
    this.message,
    this.serverUrl = '',
  });

  bool get isAvailable => availability == PicWordsAvailability.available;

  bool get isNotInstalled =>
      availability == PicWordsAvailability.notInstalled;

  /// 探测尚未有结果（含「还没开始」）。
  bool get isChecking =>
      availability == PicWordsAvailability.unknown ||
      availability == PicWordsAvailability.checking;

  /// 已经拿到确定性结论、不需要再问一次。
  bool get isSettled => isAvailable || isNotInstalled;

  @override
  bool operator ==(Object other) =>
      other is PicWordsState &&
      other.availability == availability &&
      other.message == message &&
      other.serverUrl == serverUrl;

  @override
  int get hashCode => Object.hash(availability, message, serverUrl);
}
