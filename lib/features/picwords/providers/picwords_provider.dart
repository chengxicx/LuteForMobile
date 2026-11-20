import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/network_providers.dart';
import '../models/picwords_state.dart';

/// 探测服务器上是否装了 `lute-picwords`（看图背单词）。
///
/// 结论是**全局缓存**的：切 tab、IndexedStack 重建都不会重发请求，只有点
/// Retry 或换服务器（[PicWordsState.serverUrl] 不匹配）才重新问一次。这样
/// 离线时进 Review 不会被一条 6 秒的请求反复卡住。
class PicWordsProbeNotifier extends Notifier<PicWordsState> {
  /// 并发去重：连点两次 Retry 只发一条。
  Future<void>? _inFlight;

  @override
  PicWordsState build() => const PicWordsState();

  /// 落地页挂载时调用。
  ///
  /// 已有确定性结论（可用 / 确实没装）且服务器没换过，就不再请求。
  /// 「问不到」这类不确定结论**不自动重试** —— 离线时每次切 tab 都重试等于
  /// 每次切 tab 都卡一条超时；用户点 Retry 才重查。
  Future<void> ensureProbed({required String serverUrl}) {
    if (state.isSettled && state.serverUrl == serverUrl) {
      return Future<void>.value();
    }
    return probe(serverUrl: serverUrl);
  }

  /// 用户点 Retry（或 [ensureProbed] 判定需要重查）时调用。
  Future<void> probe({required String serverUrl}) {
    final running = _inFlight;
    if (running != null) return running;

    final future = _run(serverUrl);
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
    });
  }

  Future<void> _run(String serverUrl) async {
    if (serverUrl.isEmpty) {
      state = const PicWordsState(
        availability: PicWordsAvailability.unreachable,
        message: 'Set the server address in Settings \u203a Server first.',
      );
      return;
    }

    state = PicWordsState(
      availability: PicWordsAvailability.checking,
      serverUrl: serverUrl,
    );

    try {
      final installed = await ref.read(apiServiceProvider).probePicWordsPlugin();
      state = PicWordsState(
        availability: installed
            ? PicWordsAvailability.available
            : PicWordsAvailability.notInstalled,
        serverUrl: serverUrl,
      );
    } on DioException catch (e, stackTrace) {
      ApiLogger.logError('picwords.probe', e, stackTrace: stackTrace);
      // 302 → /login 在拦截器里被包成 DioException(error: ...)，不能只 catch
      // 裸异常。
      if (e.error is ServerLoginRequiredException) {
        state = PicWordsState(
          availability: PicWordsAvailability.loginRequired,
          message: 'Your server session expired. Log in again to use this.',
          serverUrl: serverUrl,
        );
        return;
      }
      final status = e.response?.statusCode;
      final isConnectionFailure = switch (e.type) {
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => true,
        _ => false,
      };
      state = PicWordsState(
        availability: status != null
            ? PicWordsAvailability.serverError
            : (isConnectionFailure
                  ? PicWordsAvailability.unreachable
                  : PicWordsAvailability.serverError),
        message: status != null
            ? 'The server answered with $status.'
            : (isConnectionFailure
                  ? 'The server is unreachable.'
                  : 'Could not check the server.'),
        serverUrl: serverUrl,
      );
    } catch (e, stackTrace) {
      ApiLogger.logError('picwords.probe', e, stackTrace: stackTrace);
      state = PicWordsState(
        availability: PicWordsAvailability.serverError,
        message: 'Could not check the server.',
        serverUrl: serverUrl,
      );
    }
  }
}

final picWordsProvider = NotifierProvider<PicWordsProbeNotifier, PicWordsState>(
  () => PicWordsProbeNotifier(),
);
