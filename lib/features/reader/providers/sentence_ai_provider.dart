import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/ai_analysis_cache_service.dart';
import '../../../core/cache/providers/ai_analysis_cache_provider.dart';
import '../../../core/logger/api_logger.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/network_providers.dart';
import '../../../shared/providers/server_status_provider.dart';
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

  /// 本地缓存的内容仍按原样展示，但后台比对发现服务端这次给出的结果
  /// 不一样（换了 provider/模型，或服务端缓存被清后重算）。面板据此
  /// 提示「有更新」并给一个刷新入口，而不是静默继续用旧值。
  final bool serverUpdateAvailable;

  /// 这条解释是在读哪本书时拿到的。只用于让离线整本下载把「这本书的」
  /// 缓存认出来 pin 住，不影响展示。
  final int? bookId;

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
    this.serverUpdateAvailable = false,
    this.bookId,
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
    bool? serverUpdateAvailable,
    int? bookId,
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
      serverUpdateAvailable:
          serverUpdateAvailable ?? this.serverUpdateAvailable,
      bookId: bookId ?? this.bookId,
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

  void ensureAnalyzed({
    required String sentence,
    required int langId,
    int? bookId,
  }) {
    if (state.sentence == sentence &&
        state.langId == langId &&
        state.status != SentenceAiStatus.idle) {
      return;
    }
    unawaited(analyze(sentence: sentence, langId: langId, bookId: bookId));
  }

  Future<void> analyze({
    required String sentence,
    required int langId,
    int? bookId,
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
          bookId: bookId,
        );
        final entry = await running;
        if (generation != _generation) return;
        if (entry != null) {
          state = _stateFromCacheEntry(entry, sentence, langId, bookId);
          return;
        }
        // Prefetch failed -- fall through and let the panel try live; the
        // user is watching this sheet, so a visible retry is worth it.
      } else {
        final cache = ref.read(sentenceAiCacheServiceProvider);
        var resolvedKey = key;
        var entry = await cache.getFromCache(key);
        if (entry == null) {
          // 换规范化 key 之前写下的老条目仍要能读，别让一次升级把用户
          // 攒过的解释全部变成「离线没有内容」。
          resolvedKey = AiAnalysisCacheService.legacyCacheKey(
            langId,
            sentence,
          );
          entry = await cache.getFromCache(resolvedKey);
        }
        if (generation != _generation) return;
        if (entry != null) {
          state = _stateFromCacheEntry(entry, sentence, langId, bookId);
          // 缓存是永久的，但服务端结果可能已经变了（换模型、清缓存重算）。
          // 先按本地内容即时显示，再在后台比对一次；有差异就挂个提示。
          _scheduleServerCheck(
            key: resolvedKey,
            sentence: sentence,
            langId: langId,
            cached: entry,
            generation: generation,
          );
          return;
        }
      }
    }

    _startStream(
      sentence: sentence,
      langId: langId,
      bookId: bookId,
      generation: generation,
    );
  }

  /// Schedules background prefetches for the sentences that follow the one
  /// the user is currently reading, so opening the AI card on them is
  /// instant.  Called by the sentence reader screen on every sentence change.
  void schedulePrefetch({
    required List<String> upcoming,
    required int langId,
    int? bookId,
  }) {
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
          (_) => _prefetchOne(
            sentence: sentence,
            langId: langId,
            bookId: bookId,
          ),
        );
      }
    });
  }

  Future<void> _prefetchOne({
    required String sentence,
    required int langId,
    int? bookId,
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

    final cache = ref.read(sentenceAiCacheServiceProvider);
    var cached = await cache.getFromCache(key);
    cached ??= await cache.getFromCache(
      AiAnalysisCacheService.legacyCacheKey(langId, sentence),
    );
    if (cached != null) return;

    final future = _analyzeAndCache(
      sentence: sentence,
      langId: langId,
      key: key,
      bookId: bookId,
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

  /// 服务端比对的最小间隔：每句每天最多比对一次。服务端自己也有结果缓存，
  /// 命中时这次请求几乎不花代价；限频只是避免每次开面板都白跑一趟网络。
  static const int _serverCheckIntervalMs = 24 * 60 * 60 * 1000;

  void _scheduleServerCheck({
    required String key,
    required String sentence,
    required int langId,
    required AiAnalysisCacheEntry cached,
    required int generation,
  }) {
    if (!ServerStatusManager.isReachable) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = cached.verifiedAt;
    if (last != null && now - last < _serverCheckIntervalMs) return;
    unawaited(
      _checkServer(
        key: key,
        sentence: sentence,
        langId: langId,
        cached: cached,
        generation: generation,
      ),
    );
  }

  /// 在线比对：取服务端「现在」的答案，与本地缓存的内容指纹比较。
  ///
  /// 只提示、不覆盖 —— 用户点了刷新才重新流式拉取并落缓存。服务端没有
  /// 版本号/updated_at（加字段要另发一轮服务端），但结果内容本身就是它
  /// 现在的答案，指纹一变就说明确实变了。
  Future<void> _checkServer({
    required String key,
    required String sentence,
    required int langId,
    required AiAnalysisCacheEntry cached,
    required int generation,
  }) async {
    final payload = await _consumeStream(
      sentence: sentence,
      langId: langId,
      logTag: 'sentenceAi.check',
    );
    // 失败不算「比对过」：下次打开面板还能再试。
    if (payload.errorKind != null || !payload.hasContent) return;

    await ref.read(sentenceAiCacheServiceProvider).markVerified(key);
    if (generation != _generation) return;

    final serverHash = AiAnalysisCacheService.payloadHash(
      payload.result?.toJson(),
      payload.fallbackText,
    );
    final cachedHash = AiAnalysisCacheService.payloadHash(
      cached.result,
      cached.fallbackText,
    );
    if (serverHash == cachedHash) return;

    debugPrint('[sentence-ai] server payload changed key=$key');
    state = state.copyWith(serverUpdateAvailable: true);
  }

  /// Consumes a full analysis stream without touching UI state and caches
  /// the final payload.  Returns null on any failure.
  Future<AiAnalysisCacheEntry?> _analyzeAndCache({
    required String sentence,
    required int langId,
    required String key,
    int? bookId,
  }) async {
    final payload = await _consumeStream(
      sentence: sentence,
      langId: langId,
      logTag: 'sentenceAi.prefetch',
    );
    if (payload.errorKind != null) {
      if (payload.errorKind == 'unsupported') _unsupportedLangs.add(langId);
      return null;
    }
    if (!payload.hasContent) return null;

    await ref.read(sentenceAiCacheServiceProvider).saveToCache(
          key: key,
          result: payload.result?.toJson(),
          fallbackText: payload.fallbackText,
          provider: payload.provider,
          model: payload.model,
          bookId: bookId,
        );
    return AiAnalysisCacheEntry(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sizeInBytes: 0,
      result: payload.result?.toJson(),
      fallbackText: payload.fallbackText,
      provider: payload.provider,
      model: payload.model,
      verifiedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 吃完整条 SSE 流，不碰 UI、不写缓存。预取和在线比对共用。
  Future<_AiPayload> _consumeStream({
    required String sentence,
    required int langId,
    required String logTag,
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
      ApiLogger.logError(logTag, error, stackTrace: stackTrace);
      return const _AiPayload(errorKind: 'network');
    }

    if (errorKind != null) {
      if (errorKind == 'unsupported') _unsupportedLangs.add(langId);
      return _AiPayload(errorKind: errorKind);
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

    return _AiPayload(
      result: result,
      fallbackText: fallbackText,
      provider: provider,
      model: model,
    );
  }

  void _startStream({
    required String sentence,
    required int langId,
    required int generation,
    int? bookId,
  }) {
    state = SentenceAiState(
      status: SentenceAiStatus.streaming,
      sentence: sentence,
      langId: langId,
      bookId: bookId,
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
    int? bookId,
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
      bookId: bookId,
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
        // 服务端送完结果不一定立刻关连接（长连接 keep-alive），不能只靠
        // onDone 落缓存，否则这条解释永远进不了本地，离线时也就没有内容。
        _cacheCurrentResult();
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
            bookId: state.bookId,
          ),
    );
  }
}

final sentenceAiProvider =
    NotifierProvider<SentenceAiNotifier, SentenceAiState>(
  () => SentenceAiNotifier(),
);

/// [_consumeStream] 的返回值：服务端这次给出的内容与来源。
class _AiPayload {
  final SentenceAiResult? result;
  final String? fallbackText;
  final String? provider;
  final String? model;
  final String? errorKind;

  const _AiPayload({
    this.result,
    this.fallbackText,
    this.provider,
    this.model,
    this.errorKind,
  });

  bool get hasContent =>
      result != null || (fallbackText != null && fallbackText!.isNotEmpty);
}
