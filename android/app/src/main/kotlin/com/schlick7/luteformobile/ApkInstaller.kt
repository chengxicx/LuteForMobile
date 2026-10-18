package com.schlick7.luteformobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 应用内自更新的安装桥：Help 页"Check for Updates"下载完 APK 后，
/// 通过 `com.schlick7.luteformobile/apk_installer` 通道调用这里拉起
/// 系统安装器。
///
/// Android 8+（API 26+）安装外部来源 APK 需要 REQUEST_INSTALL_PACKAGES
/// 权限声明 + 用户在系统设置里逐应用授予"安装未知应用"；未授权时先
/// 跳授权页，用户回来后由 Dart 侧重查 [canInstall]。
class ApkInstaller(private val context: Context) {

    fun registerMethodChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.schlick7.luteformobile/apk_installer"
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canRequestInstalls())
                "openPermissionSettings" -> {
                    try {
                        openPermissionSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_FAILED", e.message, null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "path is required", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canRequestInstalls(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            // API 24/25 没有 per-app 开关，系统安装器自己会引导用户。
            true
        }
    }

    private fun openPermissionSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package://${context.packageName}")
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("APK not found: $path")
        }
        // APK 在应用私有目录，必须走 FileProvider 把读权限临时授给系统
        // 安装器；直接 file:// URI 在 API 24+ 会抛 FileUriExposedException。
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            )
        }
        context.startActivity(intent)
    }
}
