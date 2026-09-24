import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thrown when the server redirects a request to /login, i.e. multi-user
/// mode is enabled and the client has no valid session cookie.
class ServerLoginRequiredException implements Exception {
  const ServerLoginRequiredException();

  @override
  String toString() =>
      'Server login required. Please log in with your lute account in Settings.';
}

/// Result of POST /login.
class LoginResult {
  final bool success;
  final String message;

  const LoginResult._(this.success, this.message);

  factory LoginResult.ok() => const LoginResult._(true, 'Logged in');
  factory LoginResult.failure(String message) => LoginResult._(false, message);
}

/// Diagnostic result of GET /info.
class ServerInfoCheck {
  final bool ok;
  final bool requiresLogin;
  final bool requiresBasicAuth;
  final String version;
  final String message;

  const ServerInfoCheck({
    required this.ok,
    this.requiresLogin = false,
    this.requiresBasicAuth = false,
    this.version = '',
    this.message = '',
  });
}

enum SessionStatus { unknown, loggedIn, loggedOut, loginRequired }

/// Central holder of the server session state (multi-user login cookie from
/// lute-v3 3.12.0+) plus the optional proxy Basic Auth credentials.
///
/// Static so that Dio interceptors, static services (BackupService) and
/// image/audio loaders can read the current headers without a widget ref.
/// Mirrors the ServerStatusManager pattern: widgets watch [sessionProvider],
/// which listens to this manager.
class SessionManager {
  static const String _keyLuteUsername = 'lute_login_username';
  static const String _keyLutePassword = 'lute_login_password';
  static const String _keySessionCookie = 'lute_session_cookie';
  static const String _keySessionCookieUrl = 'lute_session_cookie_url';

  static String _serverUrl = '';
  static String _basicAuthUser = '';
  static String _basicAuthPassword = '';
  static String _luteUsername = '';
  static String _lutePassword = '';
  static String _cookie = '';
  static SessionStatus _status = SessionStatus.unknown;

  static final List<void Function()> _listeners = [];
  static Future<bool>? _pendingRelogin;

  static SessionStatus get status => _status;
  static bool get isLoggedIn => _status == SessionStatus.loggedIn;
  static String get username => _luteUsername;
  static String get serverUrl => _serverUrl;
  static bool get hasRememberedCredentials =>
      _luteUsername.isNotEmpty && _lutePassword.isNotEmpty;

  /// Basic Auth credentials for the proxy in front of the Lute server.
  /// Used by in-app WebViews (the Bilibili DASH relay), whose media/XHR
  /// requests cannot go through the Dio interceptor that [authHeaders]
  /// powers.
  static String get basicAuthUser => _basicAuthUser;
  static String get basicAuthPassword => _basicAuthPassword;

  /// The raw multi-user `session=...` cookie header, or null when logged
  /// out.  A WebView installs it via CookieManager so the `/read` stream
  /// endpoints pass the multi-user login check.
  static String? get sessionCookie => _cookie.isEmpty ? null : _cookie;

  static void addListener(void Function() callback) {
    if (!_listeners.contains(callback)) _listeners.add(callback);
  }

  static void removeListener(void Function() callback) {
    _listeners.remove(callback);
  }

  static void _notify() {
    for (final callback in List.of(_listeners)) {
      callback();
    }
  }

  /// Restores persisted credentials and the session cookie (only if it was
  /// issued for the currently configured server).
  static Future<void> hydrate(String serverUrl) async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = serverUrl;
    _basicAuthUser = prefs.getString('basic_auth_user') ?? '';
    _basicAuthPassword = prefs.getString('basic_auth_password') ?? '';
    _luteUsername = prefs.getString(_keyLuteUsername) ?? '';
    _lutePassword = prefs.getString(_keyLutePassword) ?? '';
    final cookieUrl = prefs.getString(_keySessionCookieUrl) ?? '';
    final cookie = prefs.getString(_keySessionCookie) ?? '';
    if (cookie.isNotEmpty && cookieUrl == serverUrl) {
      _cookie = cookie;
      _status = SessionStatus.loggedIn;
    } else {
      _cookie = '';
      _status = _serverUrl.isEmpty ? SessionStatus.unknown : SessionStatus.loggedOut;
    }
    _notify();
  }

  static void updateServerUrl(String url) {
    if (_serverUrl == url) return;
    _serverUrl = url;
    _cookie = '';
    _status = url.isEmpty ? SessionStatus.unknown : SessionStatus.loggedOut;
    _persistCookie();
    _notify();
  }

  static void updateBasicAuth(String user, String password) {
    _basicAuthUser = user;
    _basicAuthPassword = password;
  }

  /// Headers every authenticated request must carry: the multi-user session
  /// cookie and, when configured, the proxy Basic Auth credentials.
  static Map<String, String> authHeaders() {
    final headers = <String, String>{};
    if (_basicAuthUser.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$_basicAuthUser:$_basicAuthPassword'))}';
    }
    if (_cookie.isNotEmpty) {
      headers['Cookie'] = _cookie;
    }
    return headers;
  }

  /// Logs in against the lute multi-user endpoint (POST /login, form-encoded).
  /// On success the Flask session cookie is extracted and persisted.
  static Future<LoginResult> login(
    String username,
    String password, {
    bool remember = true,
  }) async {
    if (_serverUrl.isEmpty) {
      return LoginResult.failure('Server URL is not configured.');
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 10),
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    try {
      final response = await dio.post(
        '$_serverUrl/login',
        data:
            'username=${Uri.encodeComponent(username)}&password=${Uri.encodeComponent(password)}',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: authHeaders(),
          extra: {'noRetry': true},
        ),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 300 && statusCode < 400) {
        final cookie = _extractSessionCookie(response.headers['set-cookie']);
        if (cookie == null) {
          return LoginResult.failure(
            'Login redirected but no session cookie was returned.',
          );
        }
        _cookie = cookie;
        _luteUsername = username;
        _lutePassword = remember ? password : '';
        _status = SessionStatus.loggedIn;
        await _persistLogin();
        final check = await checkServerInfo(_serverUrl);
        if (!check.ok) {
          return LoginResult.failure(
            'Logged in but the server did not accept the session: '
            '${check.message}',
          );
        }
        _notify();
        return LoginResult.ok();
      }
      if (statusCode == 200) {
        return LoginResult.failure('Wrong username or password.');
      }
      return LoginResult.failure('Unexpected response (HTTP $statusCode).');
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return LoginResult.failure(
          'HTTP Basic Auth required (401). Fill in the Basic Auth fields.',
        );
      }
      return LoginResult.failure(_describeDioError(e));
    } catch (e) {
      return LoginResult.failure('Login failed: $e');
    }
  }

  static Future<void> logout() async {
    if (_serverUrl.isNotEmpty && _cookie.isNotEmpty) {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      try {
        await dio.post(
          '$_serverUrl/logout',
          options: Options(headers: authHeaders()),
        );
      } catch (_) {
        // Best effort: clear the local session regardless.
      }
    }
    _cookie = '';
    _lutePassword = '';
    _status = _serverUrl.isEmpty ? SessionStatus.unknown : SessionStatus.loggedOut;
    await _persistLogin();
    _notify();
  }

  /// Called when a request came back redirected to /login. Re-logs in with
  /// the remembered credentials if available. Concurrent callers share the
  /// in-flight attempt (the server rate-limits failed logins).
  static Future<bool> tryAutoRelogin() async {
    if (_pendingRelogin != null) return _pendingRelogin!;
    if (!hasRememberedCredentials || _serverUrl.isEmpty) {
      _status = SessionStatus.loginRequired;
      _notify();
      return false;
    }
    final future = _doAutoRelogin();
    _pendingRelogin = future;
    try {
      return await future;
    } finally {
      _pendingRelogin = null;
    }
  }

  static Future<bool> _doAutoRelogin() async {
    final result = await login(_luteUsername, _lutePassword, remember: true);
    if (!result.success) {
      _status = SessionStatus.loginRequired;
      _cookie = '';
      _notify();
      return false;
    }
    return true;
  }

  static void markLoginRequired() {
    if (_status == SessionStatus.loginRequired) return;
    _status = SessionStatus.loginRequired;
    _notify();
  }

  static void markLoggedIn() {
    if (_status == SessionStatus.loggedIn) return;
    _status = SessionStatus.loggedIn;
    _notify();
  }

  /// Probes GET /info. Reports whether the server is reachable and usable
  /// (200), needs a login (302 to /login), or rejected the Basic Auth
  /// credentials (401).
  ///
  /// [basicAuthUser]/[basicAuthPassword] override the stored Basic Auth
  /// credentials (used by the settings screen to test unsaved form values).
  static Future<ServerInfoCheck> checkServerInfo(
    String url, {
    String? basicAuthUser,
    String? basicAuthPassword,
  }) async {
    if (url.isEmpty) {
      return const ServerInfoCheck(ok: false, message: 'Server URL not set.');
    }
    final headers = authHeaders();
    if (basicAuthUser != null) {
      headers.remove('Authorization');
      if (basicAuthUser.isNotEmpty) {
        headers['Authorization'] =
            'Basic ${base64Encode(utf8.encode('$basicAuthUser:${basicAuthPassword ?? ''}'))}';
      }
    }
    // Never send the session cookie to a server it was not issued for.
    if (url != _serverUrl) {
      headers.remove('Cookie');
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 5),
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    try {
      final response = await dio.get(
        '$url/info',
        options: Options(headers: headers),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 300 && statusCode < 400) {
        final location = response.headers.value('location') ?? '';
        if (location.contains('/login')) {
          return const ServerInfoCheck(
            ok: false,
            requiresLogin: true,
            message: 'Server requires login.',
          );
        }
        return ServerInfoCheck(
          ok: false,
          message: 'Unexpected redirect to $location',
        );
      }
      if (statusCode == 200) {
        final version = _extractVersion(response.data);
        return ServerInfoCheck(ok: true, version: version);
      }
      return ServerInfoCheck(
        ok: false,
        message: 'Unexpected response (HTTP $statusCode).',
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) {
        return const ServerInfoCheck(
          ok: false,
          requiresBasicAuth: true,
          message: 'HTTP Basic Auth required (401).',
        );
      }
      if (status != null && status >= 300 && status < 400) {
        final location = e.response!.headers.value('location') ?? '';
        if (location.contains('/login')) {
          return const ServerInfoCheck(
            ok: false,
            requiresLogin: true,
            message: 'Server requires login.',
          );
        }
      }
      return ServerInfoCheck(ok: false, message: _describeDioError(e));
    } catch (e) {
      return ServerInfoCheck(ok: false, message: 'Connection failed: $e');
    }
  }

  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out.';
      case DioExceptionType.connectionError:
        return 'Could not connect to the server.';
      default:
        return e.message ?? e.type.name;
    }
  }

  static String _extractVersion(dynamic data) {
    if (data is Map && data['version'] != null) {
      return data['version'].toString();
    }
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map && decoded['version'] != null) {
          return decoded['version'].toString();
        }
      } catch (_) {}
    }
    return '';
  }

  /// Extracts the Flask `session=...` cookie pair from Set-Cookie headers.
  static String? _extractSessionCookie(List<String?>? setCookies) {
    if (setCookies == null) return null;
    for (final header in setCookies) {
      if (header == null) continue;
      final match = RegExp(
        r'(^|[\s,;])session=([^;]*)',
        caseSensitive: false,
      ).firstMatch(header);
      if (match != null) {
        return 'session=${match.group(2)}';
      }
    }
    return null;
  }

  static Future<void> _persistLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLuteUsername, _luteUsername);
    await prefs.setString(_keyLutePassword, _lutePassword);
    await _persistCookie();
  }

  static Future<void> _persistCookie() async {
    final prefs = await SharedPreferences.getInstance();
    if (_cookie.isEmpty) {
      await prefs.remove(_keySessionCookie);
      await prefs.remove(_keySessionCookieUrl);
    } else {
      await prefs.setString(_keySessionCookie, _cookie);
      await prefs.setString(_keySessionCookieUrl, _serverUrl);
    }
  }
}

class SessionState {
  final SessionStatus status;
  final String username;

  const SessionState({this.status = SessionStatus.unknown, this.username = ''});

  SessionState copyWith({SessionStatus? status, String? username}) {
    return SessionState(
      status: status ?? this.status,
      username: username ?? this.username,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SessionState &&
        other.status == status &&
        other.username == username;
  }

  @override
  int get hashCode => Object.hash(status, username);
}

/// Riverpod mirror of [SessionManager] for widgets (settings screen, banners).
class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    SessionManager.addListener(_syncFromManager);
    ref.onDispose(() => SessionManager.removeListener(_syncFromManager));
    return SessionState(
      status: SessionManager.status,
      username: SessionManager.username,
    );
  }

  void _syncFromManager() {
    final next = SessionState(
      status: SessionManager.status,
      username: SessionManager.username,
    );
    if (state != next) state = next;
  }

  Future<LoginResult> login(String username, String password) {
    return SessionManager.login(username, password);
  }

  Future<void> logout() => SessionManager.logout();
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(() {
      return SessionNotifier();
    });
