import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/app.dart';
import 'package:song_mobile/core/cache/audio_cache_service.dart';
import 'package:song_mobile/core/providers/initial_providers.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/core/outbox/outbox_store.dart';
import 'package:song_mobile/core/outbox/providers/outbox_provider.dart';
import 'package:song_mobile/core/prefs/legacy_scope_migration.dart';
import 'package:song_mobile/core/services/server_health_service.dart';
import 'package:song_mobile/core/services/termux_service.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';
import 'package:song_mobile/hive_registrar.g.dart';
import 'package:song_mobile/features/settings/models/settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final localUrl = prefs.getString('local_url') ?? '';
  final useTermux = prefs.getBool('use_termux') ?? false;
  final serverUrl = useTermux ? Settings.termuxUrl : localUrl;
  final basicAuthUser = prefs.getString('basic_auth_user') ?? '';
  final basicAuthPassword = prefs.getString('basic_auth_password') ?? '';

  if (kIsWeb) {
    await Hive.initFlutter();
  } else {
    final cacheDir = await getApplicationCacheDirectory();
    await Hive.initFlutter(cacheDir.path);
  }
  Hive.registerAdapters();

  // 音频缓存里的"历史版本 + 断点残片"回收。
  //
  // 服务端给音源 URL 挂了 `?v=<音频文件 mtime>`（`lute/book/service.py:
  // media_audio_url`），换了音频就换 URL，旧版本的缓存文件再没人引用，却一直
  // 占着 6–64MB。启动时扫一次，不等它 —— 回收是纯本地 unlink，失败也只是
  // 白留几 MB，不能拖慢首帧。
  //
  // 这里**不传** knownBookIds：书架还没拉到，拿空集合当"什么书都没有"会把
  // 用户所有离线音频删光。带书架的那次回收在设置页的 Storage 卡片里做。
  unawaited(AudioCacheService().collectOrphans());

  ServerStatusManager.setConnecting();

  // Restore the multi-user session cookie and Basic Auth credentials for
  // the effective server URL before any network activity.
  await SessionManager.hydrate(serverUrl);

  // Claim the pre-scope preference keys once, using the identity the device
  // was last used with.  Doing this before the first frame (instead of on the
  // first read) stops a guest account from inheriting the owner's dictionary
  // and book-language choices.
  await migrateLegacyScopedPrefs();

  // Pending offline edits, read before the first frame so the reader can
  // paint them straight away instead of showing the stale server colour and
  // then flipping once the outbox loads.  Injected below, alongside the URL.
  final outboxStore = HiveOutboxStore();
  final initialOutbox = await outboxStore.readAll();

  // 健康检查 / 自动重登挪到首帧之后。
  //
  // 这一段原本整段挡在 runApp 前：服务器连不上时要先吃满 connect 5s，
  // 需要重登时再叠上 15s，期间界面一个字都出不来。现在先让首帧落地
  // （书架从本地缓存渲染），检查结果回来再写进 ServerStatusManager ——
  // BooksProvider、ApiRequestQueue、outbox 都挂了它的监听，可达性一翻
  // 它们就各自自愈，和原来「启动时就已知不可达」的路径是同一套。
  //
  // 检查期间的语义与「先检查再启动」保持一致：ServerStatusManager 的
  // 可达性默认是 true（见 server_status_provider.dart），首屏那几个请求
  // 照常发出；真的连不上时 Dio 拦截器会把可达性翻成 false，随后的检查
  // 只是确认这个判定。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      _checkServerAfterFirstFrame(
        serverUrl: serverUrl,
        useTermux: useTermux,
        basicAuthUser: basicAuthUser,
        basicAuthPassword: basicAuthPassword,
      ),
    );
  });

  runApp(
    ProviderScope(
      overrides: [
        initialServerUrlProvider.overrideWithValue(serverUrl),
        initialOutboxEntriesProvider.overrideWithValue(initialOutbox),
        outboxStoreProvider.overrideWithValue(outboxStore),
      ],
      child: const App(),
    ),
  );
}

/// 首帧之后才开始的服务端探测：可达性判定、失效会话的静默重登、
/// 以及顺带的自动备份对账。
///
/// 与原来的 main() 同步版本逐条对应，唯一区别是它不再挡住首帧。
Future<void> _checkServerAfterFirstFrame({
  required String serverUrl,
  required bool useTermux,
  required String basicAuthUser,
  required String basicAuthPassword,
}) async {
  if (useTermux && serverUrl == Settings.termuxUrl) {
    final isRunning = await TermuxService.isServerRunning(serverUrl);
    print('main.dart: Android server check: $isRunning');
    ServerStatusManager.setReachable(isRunning);
  } else if (serverUrl.isNotEmpty) {
    final health = await ServerHealthService.check(serverUrl);
    print(
      'main.dart: Server health check: ok=${health.ok} '
      'requiresLogin=${health.requiresLogin} ${health.message}',
    );
    if (health.ok) {
      ServerStatusManager.setReachable(true);
    } else if (health.requiresLogin) {
      // The server answered but the multi-user session is gone. Try a
      // silent re-login with remembered credentials; otherwise surface the
      // login-required state.
      //
      // 可达性必须置 true：服务器在线只是要登录，和「连不上」是两回事。
      // 以前这里在重登失败时 setReachable(recheck.ok) —— recheck 还是
      // requiresLogin、ok=false —— 于是启动后第一批请求全部被扣进
      // ApiRequestQueue，队列探针紧接着发现 requiresLogin 又把可达性翻回
      // true 并一次性重放，nginx 里就是冷启动的一串 302。语义与队列保持
      // 一致（队列的 _processQueue 同样把 requiresLogin 当作可达）：请求
      // 直接发出，各自拿到一次明确的 login-required 失败，不再有排队后的
      // 集中重放。
      final recovered = await SessionManager.tryAutoRelogin();
      ServerStatusManager.setReachable(true);
      if (!recovered) {
        SessionManager.markLoginRequired();
      }
    } else {
      ServerStatusManager.setReachable(false);
    }
  } else {
    ServerStatusManager.setReachable(false);
  }

  ServerStatusManager.setInitialCheckComplete(true);

  if (serverUrl.isNotEmpty) {
    final apiService = ApiService(
      baseUrl: serverUrl,
      basicAuthUser: basicAuthUser,
      basicAuthPassword: basicAuthPassword,
    );
    // 自动备份索引（/backup/index + /settings/index，共约 100KB）纯粹是
    // 后台对账，却原来在 runApp 前就发出去，正好撞上阅读路径的冷启动
    // 窗口。压到 8 秒后 —— 那时首屏早已落定；进程若没活到那时，下次
    // 启动照样会查。
    Future.delayed(const Duration(seconds: 8), apiService.triggerAutoBackup);
  }
}
