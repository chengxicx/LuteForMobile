import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';

/// Programmable HTTP adapter: either answer a status code or throw the given
/// Dio error, without touching the network.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.statusCode});

  final int? statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '<html></html>',
      statusCode ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.textPlainContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DioException _connectionFailure(
  RequestOptions options, [
  DioExceptionType type = DioExceptionType.connectionTimeout,
]) {
  return DioException(requestOptions: options, type: type);
}

ApiService _apiWith(HttpClientAdapter adapter, {String baseUrl = ''}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiService(baseUrl: baseUrl, dio: dio);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    ServerStatusManager.setReachable(true);
  });

  group('reachability only follows real connection failures', () {
    test('HTTP 400 leaves the app online', () async {
      final api = _apiWith(_StubAdapter(statusCode: 400));

      await expectLater(
        api.getTermFormById(1, bypassQueue: true),
        throwsA(isA<DioException>()),
      );

      expect(
        ServerStatusManager.isReachable,
        isTrue,
        reason: 'a 4xx means the server answered, not that it is down',
      );
    });

    test('connection timeout marks the app unreachable', () async {
      final api = _apiWith(
        _FailingAdapter(
          (options) => _connectionFailure(options),
        ),
      );

      await expectLater(
        api.getTermFormById(1, bypassQueue: true),
        throwsA(isA<DioException>()),
      );

      expect(ServerStatusManager.isReachable, isFalse);
    });

    test('failFast term-form timeout does NOT flip the app offline', () async {
      final api = _apiWith(
        _FailingAdapter(
          (options) =>
              _connectionFailure(options, DioExceptionType.receiveTimeout),
        ),
      );

      await expectLater(
        api.getTermFormById(1),
        throwsA(isA<DioException>()),
      );

      expect(
        ServerStatusManager.isReachable,
        isTrue,
        reason: 'the 2s/3s form budget must not become a global verdict',
      );
    });

    test('noQueue shelf read timeout does NOT flip the app offline', () async {
      final api = _apiWith(
        _FailingAdapter(
          (options) =>
              _connectionFailure(options, DioExceptionType.connectionTimeout),
        ),
      );

      await expectLater(api.getActiveBooks(), throwsA(isA<DioException>()));

      expect(ServerStatusManager.isReachable, isTrue);
    });
  });

  group('identity changes reset reachability', () {
    test('server URL change resets an offline verdict', () async {
      ServerStatusManager.setReachable(false);

      SessionManager.updateServerUrl('https://new.example.test');

      expect(ServerStatusManager.isReachable, isTrue);
    });

    test('logout resets an offline verdict', () async {
      ServerStatusManager.setReachable(false);
      await SessionManager.logout();

      expect(ServerStatusManager.isReachable, isTrue);
    });

    test('successful login clears a stale unreachable flag', () async {
      // flutter_test installs an HttpOverrides that turns every request into a
      // 400; this test needs one real loopback socket.
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/login') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('set-cookie', 'session=abc123; Path=/');
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('<html><body>Lute 1.0</body></html>');
        }
        await request.response.close();
      });

      try {
        SessionManager.updateServerUrl(
          'http://127.0.0.1:${server.port}',
        );
        ServerStatusManager.setReachable(false);

        final result = await SessionManager.login(
          'owner',
          'secret',
          remember: false,
        );

        expect(result.success, isTrue, reason: result.message);
        expect(ServerStatusManager.isReachable, isTrue);
      } finally {
        await server.close(force: true);
        SessionManager.updateServerUrl('');
        HttpOverrides.global = previousOverrides;
      }
    });
  });
}

/// Adapter that throws whatever [buildError] returns.
class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.buildError);

  final DioException Function(RequestOptions options) buildError;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw buildError(options);
  }

  @override
  void close({bool force = false}) {}
}
