import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/features/picwords/models/picwords_state.dart';
import 'package:song_mobile/features/picwords/providers/picwords_provider.dart';
import 'package:song_mobile/shared/providers/network_providers.dart';

class MockApiService extends Mock implements ApiService {}

/// Per-test harness (getters are illegal inside main()).
class Harness {
  final MockApiService api = MockApiService();
  late final ProviderContainer container = ProviderContainer(
    overrides: [apiServiceProvider.overrideWithValue(api)],
  );

  PicWordsState get state => container.read(picWordsProvider);
  PicWordsProbeNotifier get notifier =>
      container.read(picWordsProvider.notifier);

  void dispose() => container.dispose();
}

DioException _dioError({
  DioExceptionType type = DioExceptionType.badResponse,
  int? status,
  Object? error,
}) {
  final options = RequestOptions(path: '/picwords/static/js/picwords.js');
  return DioException(
    requestOptions: options,
    type: type,
    error: error,
    response: status == null
        ? null
        : Response<dynamic>(requestOptions: options, statusCode: status),
  );
}

void main() {
  const url = 'https://lute.example.com';

  test('plugin present -> available', () async {
    final h = Harness();
    when(() => h.api.probePicWordsPlugin()).thenAnswer((_) async => true);

    await h.notifier.probe(serverUrl: url);

    expect(h.state.availability, PicWordsAvailability.available);
    expect(h.state.serverUrl, url);
    expect(h.state.isSettled, isTrue);
    h.dispose();
  });

  test('404 -> notInstalled (entry hidden)', () async {
    final h = Harness();
    when(() => h.api.probePicWordsPlugin()).thenAnswer((_) async => false);

    await h.notifier.probe(serverUrl: url);

    expect(h.state.isNotInstalled, isTrue);
    expect(h.state.isSettled, isTrue);
    h.dispose();
  });

  test('302 -> /login surfaces as loginRequired', () async {
    final h = Harness();
    // The session interceptor wraps the login redirect in
    // DioException.error, so catching the bare exception is not enough.
    when(() => h.api.probePicWordsPlugin()).thenThrow(
      _dioError(error: const ServerLoginRequiredException()),
    );

    await h.notifier.probe(serverUrl: url);

    expect(h.state.availability, PicWordsAvailability.loginRequired);
    expect(h.state.isSettled, isFalse, reason: 'must stay retryable');
    h.dispose();
  });

  test('connection failure -> unreachable, not "not installed"', () async {
    final h = Harness();
    when(
      () => h.api.probePicWordsPlugin(),
    ).thenThrow(_dioError(type: DioExceptionType.connectionError));

    await h.notifier.probe(serverUrl: url);

    expect(h.state.availability, PicWordsAvailability.unreachable);
    expect(h.state.message, isNotNull);
    h.dispose();
  });

  test('500 -> serverError with the status in the message', () async {
    final h = Harness();
    when(
      () => h.api.probePicWordsPlugin(),
    ).thenThrow(_dioError(status: 500));

    await h.notifier.probe(serverUrl: url);

    expect(h.state.availability, PicWordsAvailability.serverError);
    expect(h.state.message, contains('500'));
    h.dispose();
  });

  test('ensureProbed does not re-ask once a settled answer exists', () async {
    final h = Harness();
    when(() => h.api.probePicWordsPlugin()).thenAnswer((_) async => true);

    await h.notifier.ensureProbed(serverUrl: url);
    await h.notifier.ensureProbed(serverUrl: url);

    verify(() => h.api.probePicWordsPlugin()).called(1);
    h.dispose();
  });

  test('ensureProbed re-asks after the server URL changes', () async {
    final h = Harness();
    when(() => h.api.probePicWordsPlugin()).thenAnswer((_) async => false);

    await h.notifier.ensureProbed(serverUrl: url);
    await h.notifier.ensureProbed(serverUrl: 'https://other.example.com');

    verify(() => h.api.probePicWordsPlugin()).called(2);
    expect(h.state.serverUrl, 'https://other.example.com');
    h.dispose();
  });

  test('concurrent probes share one request', () async {
    final h = Harness();
    final gate = Completer<bool>();
    when(() => h.api.probePicWordsPlugin()).thenAnswer((_) => gate.future);

    final first = h.notifier.probe(serverUrl: url);
    final second = h.notifier.probe(serverUrl: url);
    gate.complete(true);
    await Future.wait([first, second]);

    verify(() => h.api.probePicWordsPlugin()).called(1);
    expect(h.state.availability, PicWordsAvailability.available);
    h.dispose();
  });

  test('empty server URL short-circuits without a request', () async {
    final h = Harness();

    await h.notifier.probe(serverUrl: '');

    expect(h.state.availability, PicWordsAvailability.unreachable);
    verifyNever(() => h.api.probePicWordsPlugin());
    h.dispose();
  });
}
