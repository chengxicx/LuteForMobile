import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/network_providers.dart';
import '../models/ai_grammar_result.dart';
import '../services/ai_grammar_service.dart';

enum AiGrammarStatus { idle, streaming, done, error }

@immutable
class AiGrammarState {
  final AiGrammarStatus status;
  final String? sentence;
  final int? langId;
  final AiGrammarMetaEvent? meta;

  /// Raw incremental output from `event: text`, shown while the structured
  /// result has not arrived yet.
  final String streamedText;
  final AiGrammarResult? result;
  final String? fallbackText;

  /// `unconfigured` / `auth` / `rate` / `timeout` / `upstream` (from the
  /// server), or `offline` / `login` / `empty` (client-side).
  final String? errorKind;
  final String? errorMessage;

  /// The provider's own message, when [errorMessage] is the readable
  /// replacement for it.
  final String? errorDetail;

  const AiGrammarState({
    this.status = AiGrammarStatus.idle,
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
      status == AiGrammarStatus.streaming &&
      result == null &&
      fallbackText == null;

  bool get hasStructuredResult => result != null && !result!.isEmpty;

  AiGrammarState copyWith({
    AiGrammarStatus? status,
    AiGrammarMetaEvent? meta,
    String? streamedText,
    AiGrammarResult? result,
    String? fallbackText,
    String? errorKind,
    String? errorMessage,
    String? errorDetail,
  }) {
    return AiGrammarState(
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

class AiGrammarNotifier extends Notifier<AiGrammarState> {
  StreamSubscription<AiGrammarEvent>? _subscription;

  /// Bumped on every request; late events from a cancelled stream are dropped.
  int _generation = 0;

  @override
  AiGrammarState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    return const AiGrammarState();
  }

  /// Starts a request unless the same sentence/language is already loaded,
  /// streaming, or failed.  Used by the tab and the word card so switching
  /// between the local and AI tabs does not re-run the analysis.
  void ensureAnalyzed({required String sentence, required int langId}) {
    if (state.sentence == sentence &&
        state.langId == langId &&
        state.status != AiGrammarStatus.idle) {
      return;
    }
    analyze(sentence: sentence, langId: langId);
  }

  void analyze({required String sentence, required int langId}) {
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _subscription = null;

    state = AiGrammarState(
      status: AiGrammarStatus.streaming,
      sentence: sentence,
      langId: langId,
    );

    final stream = ref
        .read(aiGrammarServiceProvider)
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

  void _onEvent(AiGrammarEvent event) {
    switch (event) {
      case AiGrammarMetaEvent():
        state = state.copyWith(meta: event);
      case AiGrammarTextEvent():
        state = state.copyWith(
          streamedText: state.streamedText + event.text,
        );
      case AiGrammarResultEvent():
        state = state.copyWith(
          status: AiGrammarStatus.done,
          result: event.result,
          fallbackText: event.fallbackText,
        );
      case AiGrammarErrorEvent():
        _setProviderError(event.kind, event.message);
      case AiGrammarDoneEvent():
        break;
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    ApiLogger.logError('aiGrammar.stream', error, stackTrace: stackTrace);

    if (error is AiGrammarStreamException) {
      _setProviderError('upstream', error.message);
      return;
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        // Same path as a /login redirect: the whole app learns the session
        // must be renewed, instead of this panel owning a private verdict.
        SessionManager.markLoginRequired();
        state = state.copyWith(
          status: AiGrammarStatus.error,
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
            status: AiGrammarStatus.error,
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
      'auth' => 'The server\'s AI provider rejected its API key.',
      'rate' => 'The AI provider is rate-limiting requests. Try again in a moment.',
      'timeout' => 'The AI provider timed out. Try again.',
      _ => 'The AI provider returned an error. Try again.',
    };
    state = state.copyWith(
      status: AiGrammarStatus.error,
      errorKind: kind,
      errorMessage: readable,
      errorDetail: readable == message ? null : message,
    );
  }

  void _onDone() {
    if (state.status == AiGrammarStatus.error) return;
    if (state.result != null || state.fallbackText != null) {
      state = state.copyWith(status: AiGrammarStatus.done);
      return;
    }
    final raw = state.streamedText.trim();
    if (raw.isNotEmpty) {
      state = state.copyWith(
        status: AiGrammarStatus.done,
        fallbackText: raw,
      );
      return;
    }
    state = state.copyWith(
      status: AiGrammarStatus.error,
      errorKind: 'empty',
      errorMessage: 'The AI returned no result. Try again.',
    );
  }
}

final aiGrammarServiceProvider = Provider<AiGrammarService>((ref) {
  return AiGrammarService(ref.watch(apiServiceProvider));
});

final aiGrammarProvider = NotifierProvider<AiGrammarNotifier, AiGrammarState>(
  () => AiGrammarNotifier(),
);
