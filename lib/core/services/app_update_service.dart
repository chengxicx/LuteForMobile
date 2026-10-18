import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../network/session_manager.dart';

/// 服务端版本清单（`/static/app_version.json`），随 APK 一起放在 nginx 静态
/// 目录里。示例：
///
/// ```json
/// {
///   "version": "1.3.6",
///   "build": 43,
///   "apk": "song_mobile_1.3.6_build43_20261017.apk",
///   "sha1": "da39a3ee5e6b4b0d3255bfef95601890afd80709"
/// }
/// ```
///
/// `build` 对应 Android versionCode（pubspec 的 `+N`），是唯一的新旧判据；
/// `version` 仅用于展示。`apk` 是静态目录里的文件名（同目录下载），带时间戳
/// —— CDN 按 URL 缓存，同名新包会拿到旧字节，所以文件名绝不能复用。
class AppUpdateManifest {
  final String version;
  final int build;
  final String apkFile;
  final String sha1;

  const AppUpdateManifest({
    required this.version,
    required this.build,
    required this.apkFile,
    required this.sha1,
  });

  static AppUpdateManifest? fromJson(Map<String, dynamic> json) {
    final version = json['version']?.toString() ?? '';
    final build = json['build'];
    final apk = json['apk']?.toString() ?? '';
    if (version.isEmpty || apk.isEmpty || build is! num) return null;
    return AppUpdateManifest(
      version: version,
      build: build.toInt(),
      apkFile: apk,
      sha1: json['sha1']?.toString().trim().toLowerCase() ?? '',
    );
  }
}

/// 检查结果。[error] 非 null 时其余字段无意义。
class AppUpdateCheckResult {
  final AppUpdateManifest? manifest;
  final int currentBuild;
  final String currentVersion;
  final bool updateAvailable;
  final String? error;

  const AppUpdateCheckResult({
    required this.manifest,
    required this.currentBuild,
    required this.currentVersion,
    required this.updateAvailable,
    this.error,
  });
}

/// 应用内自更新：查清单 → 下载 APK → sha1 校验。安装由 [ApkInstaller]
/// （method channel）完成，这里只管网络与文件。
class AppUpdateService {
  static const String _manifestPath = '/static/app_version.json';

  /// CDN 按 URL 缓存，清单必须带时间戳参数破缓存，否则发布新版后客户端
  /// 会一直读到旧清单。
  static Future<AppUpdateCheckResult> check(String baseUrl) async {
    final info = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(info.buildNumber) ?? 0;
    try {
      final json = await _fetchManifest(baseUrl);
      if (json == null) {
        return _error(currentBuild, info.version, 'Invalid manifest format');
      }
      return AppUpdateCheckResult(
        manifest: json,
        currentBuild: currentBuild,
        currentVersion: info.version,
        updateAvailable: json.build > currentBuild,
      );
    } catch (e) {
      return _error(currentBuild, info.version, e.toString());
    }
  }

  static AppUpdateCheckResult _error(
    int currentBuild,
    String currentVersion,
    String message,
  ) {
    return AppUpdateCheckResult(
      manifest: null,
      currentBuild: currentBuild,
      currentVersion: currentVersion,
      updateAvailable: false,
      error: message,
    );
  }

  /// 下载 APK 到应用私有目录并做 sha1 校验，返回下载文件路径。
  ///
  /// [expectedSha1] 来自版本清单；为空时跳过校验（清单缺字段不算致命）。
  /// [onProgress] 的取值是 0.0~1.0（total 未知时为 null）。
  static Future<String> downloadApk(
    String baseUrl,
    AppUpdateManifest manifest, {
    void Function(double? progress)? onProgress,
  }) async {
    final normalized = _normalizedBase(baseUrl);
    final dir = await getApplicationSupportDirectory();
    final savePath = '${dir.path}/update_${manifest.apkFile}';
    final file = File(savePath);
    if (await file.exists()) {
      await file.delete();
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // CDN 实测 33 秒 ~ 3 分钟波动，留足余量（dio 按数据块间隔计时，
      // 不是整包时限）。
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: true,
      validateStatus: (status) => status != null && status < 400,
    ));
    await dio.download(
      '$normalized/static/${manifest.apkFile}',
      savePath,
      options: Options(headers: SessionManager.authHeaders()),
      onReceiveProgress: (received, total) {
        if (onProgress != null) {
          onProgress(total > 0 ? received / total : null);
        }
      },
    );

    if (manifest.sha1.isNotEmpty) {
      final actual = await _sha1OfFile(file);
      if (actual != manifest.sha1) {
        await file.delete().catchError((_) => file);
        throw Exception(
          'Download integrity check failed (sha1 mismatch)',
        );
      }
    }
    return savePath;
  }

  static String _normalizedBase(String baseUrl) {
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  static Future<AppUpdateManifest?> _fetchManifest(String baseUrl) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: true,
      validateStatus: (status) => status != null && status < 400,
    ));
    final response = await dio.get<String>(
      '${_normalizedBase(baseUrl)}$_manifestPath',
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch.toString()},
      options: Options(headers: SessionManager.authHeaders()),
    );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    final json = jsonDecode(data);
    if (json is! Map<String, dynamic>) return null;
    return AppUpdateManifest.fromJson(json);
  }

  static Future<String> _sha1OfFile(File file) async {
    final digest = await crypto.sha1.bind(file.openRead()).first;
    return digest.toString();
  }
}
