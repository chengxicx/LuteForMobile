import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/app.dart';
import 'package:song_mobile/core/providers/initial_providers.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/core/outbox/outbox_store.dart';
import 'package:song_mobile/core/outbox/providers/outbox_provider.dart';
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

  ServerStatusManager.setConnecting();

  // Restore the multi-user session cookie and Basic Auth credentials for
  // the effective server URL before any network activity.
  await SessionManager.hydrate(serverUrl);

  // Pending offline edits, read before the first frame so the reader can
  // paint them straight away instead of showing the stale server colour and
  // then flipping once the outbox loads.  Injected below, alongside the URL.
  final outboxStore = HiveOutboxStore();
  final initialOutbox = await outboxStore.readAll();

  Future<bool>? androidHealthCheck;
  if (useTermux && serverUrl == Settings.termuxUrl) {
    androidHealthCheck = TermuxService.isServerRunning(serverUrl);
  }

  if (androidHealthCheck != null) {
    final isRunning = await androidHealthCheck;
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
    apiService.triggerAutoBackup();
  }

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
