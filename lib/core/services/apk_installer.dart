import 'package:flutter/services.dart';

/// APK 安装的 Android 侧桥（见 ApkInstaller.kt）：安装权限检查、跳转
/// 系统授权页、拉起系统安装器。
class ApkInstaller {
  static const MethodChannel _channel = MethodChannel(
    'com.schlick7.luteformobile/apk_installer',
  );

  /// Android 8+ 需要用户授予"安装未知应用"权限。
  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统的"允许安装未知应用"授权页，用户授权后回到应用重试。
  static Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod('openPermissionSettings');
    } on MissingPluginException {
      // 非 Android 平台无此通道，静默忽略。
    }
  }

  /// 拉起系统安装器安装 [filePath] 指向的 APK。
  static Future<void> install(String filePath) async {
    await _channel.invokeMethod('installApk', {'path': filePath});
  }
}
