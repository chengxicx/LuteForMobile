import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/ai_analysis_cache_service.dart';
import '../../../core/cache/providers/ai_analysis_cache_provider.dart';
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

/// The streaming endpoint, as a function so tests can fake it
/// (see [sentenceAiAnalyzeProvider]).
typedef SentenceAiAnalyzeFn = Stream<SentenceAiEvent> Function({
  required String sentence,
  required int langId,
});

final sentenceAiServiceProvider = Provider<SentenceAiService>((ref) {
  return SentenceAiService(ref.watch(apiServiceProvider));
});

final sentenceAiAnalyzeProvider = Provider<SentenceAiAnalyzeFn>((ref) {
  final service = ref.watch(sentenceAiServiceProvider);
  return ({required String sentence, required int langId}) =>
      service.analyze(sentence: sentence, langId: langId);
});

class SentenceAiNotifier extends Notifier<SentenceAiState> {
  StreamSubscription<SentenceAiEvent>? _subscription;
  int _generation = 0;

  /// Requests currently running on the network, keyed by cache key.  The
  /// panel joins an in-flight prefetch instead of firing a duplicate; the
  /// prefetcher skips sentences a panel request is already fetching.
  final Map<String, Future<AiAnalysisCacheEntry?>> _inFlight = {};

  /// Cache key -> epoch ms of the last failed prefetch; retries are held
  /// off for [_failureCooldown] so a dead network doesn't get hammered.
  final Map<String, int> _failedAt = {};

  /// Languages the server answered `unsupported` for; prefetching them is
  /// stopped for the rest of the session (the panel itself still shows the
  /// real error when the user opens it).
  final Set<int> _unsupportedLangs = {};

  Timer? _prefetchTimer;
  Future<void> _prefetchQueue = Future.value();

  final Duration _prefetchDwell;
  final Duration _failureCooldown;
  static const _prefetchLimit = 2;

  /// [prefetchDwell] and [failureCooldown] exist so tests can shrink them;
  /// production waits 4s of reading dwell before prefetching and cools down
  /// a failed sentence for 60s.
  SentenceAiNotifier({Duration? prefetchDwell, Duration? failureCooldown})
      : _prefetchDwell = prefetchDwell ?? const Duration(seconds: 4),
        _failureCooldown = failureCooldown ?? const Duration(seconds: 60);

  @override
  SentenceAiState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_subscription?.cancel());
      _subscription = null;
      _prefetchTimer?.cancel();
    });
    return const SentenceAiState();
  }

  void ensureAnalyzed({required String sentence, required int langId}) {
    if (state.sentence == sentence &&
        state.langId == langId &&
        state.status != SentenceAiStatus.idle) {
      return;
    }
    unawaited(analyze(sentence: sentence, langId: langId));
  }

  Future<void> analyze({
    required String sentence,
    required int langId,
    bool forceNetwork = false,
  }) async {
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _subscription = null;

    final key = AiAnalysisCacheService.cacheKey(langId, sentence);

    if (!forceNetwork) {
      // A prefetch for this very sentence may already be running: join it
      // instead of issuing a second request for the same text.
      final running = _inFlight[key];
      if (running != null) {
        state = SentenceAiState(
          status: SentenceAiStatus.streaming,
          sentence: sentence,
          langId: langId,
        );
        final entry = await running;
        if (generation != _generation) return;
        if (entry != null) {
          state = _stateFromCacheEntry(entry, sentence, langId);
          return;
        }
        // Prefetch failed -- fall through and let the panel try live; the
        // user is watching this sheet, so a visible retry is worth it.
      } else {
        final entry =
            await ref.read(sentenceAiCacheServiceProvider).getFromCache(key);
        if (generation != _generation) return;
        if (entry != null) {
          state = _stateFromCacheEntry(entry, sentence, langId);
          return;
        }
      }
    }

    _startStream(sentence: sentence, langId: langId, generation: generation);
  }

  /// Schedules background prefetches for the sentences that follow the one
  /// the user is currently reading, so opening the AI card on them is
  /// instant.  Called by the sentence reader screen on every sentence change.
  void schedulePrefetch({required List<String> upcoming, required int langId}) {
    _prefetchTimer?.cancel();
    if (_unsupportedLangs.contains(langId)) return;
    final sentences = upcoming
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .take(_prefetchLimit)
        .toList();
    if (sentences.isEmpty) return;
    // The dwell lets quick paging / fast scrolling through sentences go by
    // without costing any request at all.
    _prefetchTimer = Timer(_prefetchDwell, () {
      for (final sentence in sentences) {
        _prefetchQueue = _prefetchQueue.then(
          (_) => _prefetchOne(sentence: sentence, langId: langId),
        );
      }
    });
  }

  Future<void> _prefetchOne({
    required String sentence,
    required int langId,
  }) async {
    if (_unsupportedLangs.contains(langId)) return;

    final key = AiAnalysisCacheService.cacheKey(langId, sentence);
    final failedAt = _failedAt[key];
    if (failedAt != null &&
        DateTime.now().millisecondsSinceEpoch - failedAt <
            _failureCooldown.inMilliseconds) {
      return;
    }
    if (_inFlight.containsKey(key)) return;

    final cached =
        await ref.read(sentenceAiCacheServiceProvider).getFromCache(key);
    if (cached != null) return;

    final future = _analyzeAndCache(
      sentence: sentence,
      langId: langId,
      key: key,
    );
    _inFlight[key] = future;
    try {
      final entry = await future;
      if (entry == null) {
        _failedAt[key] = DateTime.now().millisecondsSinceEpoch;
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Consumes a full analysis stream without touching UI state and caches
  /// the final payload.  Returns null on any failure.
  Future<AiAnalysisCacheEntry?> _analyzeAndCache({
    required String sentence,
    required int langId,
    required String key,
  }) async {
    final streamed = StringBuffer();
    SentenceAiResult? result;
    String? fallbackText;
    String? provider;
    String? model;
    String? errorKind;

    try {
      final stream = ref.read(sentenceAiAnalyzeProvider)(
        sentence: sentence,
        langId: langId,
      );
      await for (final event in stream) {
        switch (event) {
          case SentenceAiMetaEvent():
            provider = event.provider;
            model = event.model;
          case SentenceAiTextEvent():
            streamed.write(event.text);
          case SentenceAiResultEvent():
            result = event.result;
            fallbackText = event.fallbackText;
          case SentenceAiErrorEvent():
            errorKind = event.kind;
          case SentenceAiDoneEvent():
            break;
        }
      }
    } catch (error, stackTrace) {
      ApiLogger.logError('sentenceAi.prefetch', error, stackTrace: stackTrace);
      return null;
    }

    if (errorKind != null) {
      if (errorKind == 'unsupported') _unsupportedLangs.add(langId);
      return null;
    }

    // Same end-of-stream fallbacks as the panel's [_onDone].
    if (result == null && fallbackText == null) {
      final raw = streamed.toString().trim();
      if (raw.isNotEmpty) {
        final parsed = parseSentenceAiResultPayload(raw);
        if (parsed != null && !parsed.isEmpty) {
          result = parsed;
        } else {
          fallbackText = raw;
        }
      }
    }
    if (result == null && (fallbackText == null || fallbackText.isEmpty)) {
      return null;
    }

    await ref.read(sentenceAiCacheServiceProvider).saveToCache(
          key: key,
          result: result?.toJson(),
          fallbackText: fallbackText,
          provider: provider,
          model: model,
        );
    return AiAnalysisCacheEntry(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sizeInBytes: 0,
      result: result?.toJson(),
      fallbackText: fallbackText,
      provider: provider,
      model: model,
    );
  }

  void _startStream({
    required String sentence,
    required int langId,
    required int generation,
  }) {
    state = SentenceAiState(
      status: SentenceAiStatus.streaming,
      sentence: sentence,
      langId: langId,
    );

    final stream = ref.read(sentenceAiAnalyzeProvider)(
      sentence: sentence,
      langId: langId,
    );

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

  /// Rebuilds a finished panel state from a cached payload.  `cached: true`
  /// in the meta means "served from the local cache", which keeps the
  /// widget's cached indicator truthful.
  SentenceAiState _stateFromCacheEntry(
    AiAnalysisCacheEntry entry,
    String sentence,
    int langId,
  ) {
    SentenceAiResult? result;
    if (entry.result != null) {
      final parsed = SentenceAiResult.fromJson(entry.result!);
      if (!parsed.isEmpty) result = parsed;
    }
    return SentenceAiState(
      status: SentenceAiStatus.done,
      sentence: sentence,
      langId: langId,
      meta: SentenceAiMetaEvent(
        cached: true,
        provider: entry.provider,
        model: entry.model,
      ),
      result: result,
      fallbackText: entry.fallbackText,
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
      _cacheCurrentResult();
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
        _cacheCurrentResult();
        return;
      }
      state = state.copyWith(
        status: SentenceAiStatus.done,
        fallbackText: raw,
      );
      _cacheCurrentResult();
      return;
    }
    state = state.copyWith(
      status: SentenceAiStatus.error,
      errorKind: 'empty',
      errorMessage: 'The AI returned no result. Try again.',
    );
  }

  /// Persists the result the panel just streamed in, so re-opening this
  /// sentence (even in a later session) never pays for the request again.
  void _cacheCurrentResult() {
    final sentence = state.sentence;
    final langId = state.langId;
    if (sentence == null || langId == null) return;
    final result = state.result;
    final fallbackText = state.fallbackText;
    if (result == null && (fallbackText == null || fallbackText.isEmpty)) {
      return;
    }
    unawaited(
      ref
          .read(sentenceAiCacheServiceProvider)
          .saveToCache(
            key: AiAnalysisCacheService.cacheKey(langId, sentence),
            result: result?.toJson(),
            fallbackText: fallbackText,
            provider: state.meta?.provider,
            model: state.meta?.model,
          ),
    );
  }
}

final sentenceAiProvider =
    NotifierProvider<SentenceAiNotifier, SentenceAiState>(
  () => SentenceAiNotifier(),
);
