import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';

class ServerHealthService {
  static const Duration _kDefaultTimeout = Duration(milliseconds: 500);

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: _kDefaultTimeout,
      receiveTimeout: _kDefaultTimeout,
      sendTimeout: _kDefaultTimeout,
    ),
  )..interceptors.clear();

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

    _pendingCheck = _performCheck(uri, username, password);
    try {
      return await _pendingCheck!;
    } finally {
      _pendingCheck = null;
    }
  }

  static Future<bool> _performCheck(Uri uri, String username, String password) async {
    try {
      // Use /info endpoint for health check (designed for this purpose)
      final healthUri = uri.replace(path: '/info');
      print('ServerHealthService: Sending HEAD request to $healthUri');

      final headers = <String, dynamic>{};
      if (username.isNotEmpty) {
        final basicAuth =
            'Basic ${base64Encode(utf8.encode('$username:$password'))}';
        headers['Authorization'] = basicAuth;
      }

      final startTime = DateTime.now();
      final response = await _dio.headUri(
        healthUri,
        options: Options(headers: headers),
      );
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;

      print(
        'ServerHealthService: HEAD $healthUri -> ${response.statusCode} in ${elapsed}ms',
      );
      return response.statusCode == 200;
    } on TimeoutException catch (e) {
      print(
        'ServerHealthService: HEAD ${uri.toString()} TIMEOUT - ${e.duration}',
      );
      return false;
    } on DioException catch (e) {
      print('ServerHealthService: HEAD ${uri.toString()} DIO ERROR');
      print('  - type: ${e.type}');
      print('  - message: ${e.message}');
      print('  - error: ${e.error}');
      print('  - stack trace: ${e.stackTrace}');
      return false;
    } on Exception catch (e) {
      print(
        'ServerHealthService: HEAD ${uri.toString()} EXCEPTION - ${e.runtimeType}: $e',
      );
      return false;
    }
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
