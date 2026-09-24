import 'dart:async';

import '../network/session_manager.dart';

class ServerHealthService {
  static Future<bool>? _pendingCheck;

  static Future<bool> isReachable(
    String url, {
    String username = '',
    String password = '',
  }) async {
    if (url.isEmpty) {
      print('ServerHealthService: URL is empty, returning false');
      return false;
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      print('ServerHealthService: Invalid URI "$url", returning false');
      return false;
    }

    // If already checking, return existing future
    if (_pendingCheck != null) {
      return _pendingCheck!;
    }

    _pendingCheck = _performCheck(url);
    try {
      return await _pendingCheck!;
    } finally {
      _pendingCheck = null;
    }
  }

  static Future<bool> _performCheck(String url) async {
    try {
      final result = await check(url);
      print(
        'ServerHealthService: GET $url/info -> ok=${result.ok} '
        'requiresLogin=${result.requiresLogin} '
        'requiresBasicAuth=${result.requiresBasicAuth} ${result.message}',
      );
      if (result.ok) return true;
      if (result.requiresLogin) {
        // The server answers but the multi-user session is gone. Try a
        // silent re-login with remembered credentials before reporting
        // the server as unreachable.
        final recovered = await SessionManager.tryAutoRelogin();
        if (recovered) {
          final retryResult = await check(url);
          if (retryResult.ok) return true;
        }
      }
      return false;
    } on Exception catch (e) {
      print('ServerHealthService: HEAD $url EXCEPTION - ${e.runtimeType}: $e');
      return false;
    }
  }

  /// Detailed probe used by the queue and the settings screen: distinguishes
  /// a reachable server that only needs a login from a dead one.
  static Future<ServerInfoCheck> check(String url) {
    return SessionManager.checkServerInfo(url);
  }

  static Future<bool> waitForReachable(
    String url, {
    Duration interval = const Duration(milliseconds: 200),
    int maxAttempts = 100,
    String username = '',
    String password = '',
  }) async {
    int attempts = 0;
    while (attempts < maxAttempts) {
      if (await isReachable(url, username: username, password: password)) {
        return true;
      }
      attempts++;
      if (attempts < maxAttempts) {
        await Future.delayed(interval);
      }
    }
    return false;
  }
}
