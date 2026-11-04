import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/network_providers.dart';
import '../models/sentence_ai_result.dart';
import '../services/sentence_ai_service.dart';

enum SentenceAiStatus { idle, streaming, done, error }

@immutable
class SentenceAiState {
  final SentenceAiStatus status;
  final String? sentence;
  final int? langId;
  final SentenceAiMetaEvent? meta;
  final String streamedText;
  final SentenceAiResult? result;
  final String? fallbackText;
  final String? errorKind;
  final String? errorMessage;
  final String? errorDetail;

  const SentenceAiState({
    this.status = SentenceAiStatus.idle,
    this.sentence,
    this.langId,
    this.meta,
    this.streamedText = '',
    this.result,
    this.fallbackText,
    this.errorKind,
    this.errorMessage,
    this.errorDetail,
  });

  bool get isCached => meta?.cached ?? false;

  bool get isWaiting =>
      status == SentenceAiStatus.streaming &&
      result == null &&
      fallbackText == null;

  SentenceAiState copyWith({
    SentenceAiStatus? status,
    SentenceAiMetaEvent? meta,
    String? streamedText,
    SentenceAiResult? result,
    String? fallbackText,
    String? errorKind,
    String? errorMessage,
    String? errorDetail,
  }) {
    return SentenceAiState(
      status: status ?? this.status,
      sentence: sentence,
      langId: langId,
      meta: meta ?? this.meta,
      streamedText: streamedText ?? this.streamedText,
      result: result ?? this.result,
      fallbackText: fallbackText ?? this.fallbackText,
      errorKind: errorKind ?? this.errorKind,
      errorMessage: errorMessage ?? this.errorMessage,
      errorDetail: errorDetail ?? this.errorDetail,
    );
  }
}

class SentenceAiNotifier extends Notifier<SentenceAiState> {
  StreamSubscription<SentenceAiEvent>? _subscription;
  int _generation = 0;

  @override
  SentenceAiState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    return const SentenceAiState();
  }

  void ensureAnalyzed({required String sentence, required int langId}) {
    if (state.sentence == sentence &&
        state.langId == langId &&
        state.status != SentenceAiStatus.idle) {
      return;
    }
    analyze(sentence: sentence, langId: langId);
  }

  void analyze({required String sentence, required int langId}) {
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _subscription = null;

    state = SentenceAiState(
      status: SentenceAiStatus.streaming,
      sentence: sentence,
      langId: langId,
    );

    final stream = ref
        .read(sentenceAiServiceProvider)
        .analyze(sentence: sentence, langId: langId);

    _subscription = stream.listen(
      (event) {
        if (generation != _generation) return;
        _onEvent(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _generation) return;
        _onError(error, stackTrace);
      },
      onDone: () {
        if (generation != _generation) return;
        _onDone();
      },
      cancelOnError: true,
    );
  }

  void _onEvent(SentenceAiEvent event) {
    switch (event) {
      case SentenceAiMetaEvent():
        state = state.copyWith(meta: event);
      case SentenceAiTextEvent():
        state = state.copyWith(
          streamedText: state.streamedText + event.text,
        );
      case SentenceAiResultEvent():
        state = state.copyWith(
          status: SentenceAiStatus.done,
          result: event.result,
          fallbackText: event.fallbackText,
        );
      case SentenceAiErrorEvent():
        _setProviderError(event.kind, event.message);
      case SentenceAiDoneEvent():
        break;
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    ApiLogger.logError('sentenceAi.stream', error, stackTrace: stackTrace);

    if (error is SentenceAiStreamException) {
      _setProviderError('upstream', error.message);
      return;
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        SessionManager.markLoginRequired();
        state = state.copyWith(
          status: SentenceAiStatus.error,
          errorKind: 'login',
          errorMessage: 'Your session has expired. Log in again in Settings.',
        );
        return;
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          _setProviderError('timeout', 'The AI request timed out.');
          return;
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          state = state.copyWith(
            status: SentenceAiStatus.error,
            errorKind: 'offline',
            errorMessage:
                'AI analysis needs a network connection. Check your '
                'connection and try again.',
          );
          return;
        case DioExceptionType.badResponse:
          _setProviderError('upstream', 'The server rejected the request.');
          return;
        case DioExceptionType.badCertificate:
        case DioExceptionType.cancel:
          return;
      }
    }

    _setProviderError('upstream', 'The AI request failed.');
  }

  void _setProviderError(String kind, String message) {
    final readable = switch (kind) {
      'unconfigured' => message,
      'unsupported' =>
        'AI sentence translation is turned off for this language. '
            'Turn it on in Language settings.',
      'auth' => 'The server\'s AI provider rejected its API key.',
      'rate' => 'The AI provider is rate-limiting requests. Try again in a moment.',
      'timeout' => 'The AI provider timed out. Try again.',
      _ => 'The AI provider returned an error. Try again.',
    };
    state = state.copyWith(
      status: SentenceAiStatus.error,
      errorKind: kind,
      errorMessage: readable,
      errorDetail: readable == message ? null : message,
    );
  }

  void _onDone() {
    if (state.status == SentenceAiStatus.error) return;
    if (state.result != null || state.fallbackText != null) {
      state = state.copyWith(status: SentenceAiStatus.done);
      return;
    }
    final raw = state.streamedText.trim();
    if (raw.isNotEmpty) {
      final parsed = parseSentenceAiResultPayload(raw);
      if (parsed != null && !parsed.isEmpty) {
        state = state.copyWith(
          status: SentenceAiStatus.done,
          result: parsed,
        );
        return;
      }
      state = state.copyWith(
        status: SentenceAiStatus.done,
        fallbackText: raw,
      );
      return;
    }
    state = state.copyWith(
      status: SentenceAiStatus.error,
      errorKind: 'empty',
      errorMessage: 'The AI returned no result. Try again.',
    );
  }
}

final sentenceAiServiceProvider = Provider<SentenceAiService>((ref) {
  return SentenceAiService(ref.watch(apiServiceProvider));
});

final sentenceAiProvider =
    NotifierProvider<SentenceAiNotifier, SentenceAiState>(
  () => SentenceAiNotifier(),
);
