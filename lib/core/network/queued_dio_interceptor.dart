import 'dart:async';
import 'package:dio/dio.dart';
import 'api_request_queue.dart';
import '../services/server_health_service.dart';
import 'session_manager.dart';
import '../../shared/providers/server_status_provider.dart';

class QueuedDioInterceptor extends Interceptor {
  final ApiRequestQueue _queue;

  /// 队列重放请求时必须用的那条 Dio —— 也就是 app 自己这条，带着
  /// `_addSessionInterceptor`。
  ///
  /// 以前这里传的是 `Dio()`（裸的、没有任何拦截器），于是重放**不带
  /// session cookie**：已登录的 app 一进离线就退化成匿名请求，服务端把每一条
  /// 重放都 302 到 `/login`；更糟的是裸 Dio 默认 `followRedirects: true`，它会
  /// 跟着跳到登录页、把**登录页 HTML 当成 200 的正文**返回给调用方 —— 屏幕
  /// 于是显示成空列表（单词页「No terms found」）而不是报错，看起来像数据被
  /// 清空了。冷启动时最容易撞上：启动瞬间健康检查还没成功，第一批请求被扣进
  /// 队列，一秒后网络确认可达就一次性重放出来，nginx 里就是一串 302。
  final Dio _dio;

  bool _hasQueuedTermForm = false;
  bool _wasUnreachable = false;

  QueuedDioInterceptor(this._queue, this._dio) {
    ServerStatusManager.addListener(_onServerStatusChanged);
  }

  void _onServerStatusChanged() {
    final isReachable = ServerStatusManager.isReachable;
    if (_wasUnreachable && isReachable) {
      _hasQueuedTermForm = false;
    }
    _wasUnreachable = !isReachable;
  }

  bool _isTermFormFetch(RequestOptions options) {
    return options.method == 'GET' &&
        options.uri.path.contains('/read/edit_term/');
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 队列自己在重放这条请求：必须直接放行。
    //
    // 扣回队列会变成自我循环，而且调用方的 completer 早就在这一轮完成了 ——
    // 再重放一次就是「同一个 POST 被执行两次」，正是
    // [ApiRequestQueue] 的 deadline 注释里要避免的事。
    if (options.extra[ApiRequestQueue.extraFromQueue] == true) {
      handler.next(options);
      return;
    }

    // `bypassQueue` means "never queue me, and never tell me the server is
    // down -- just try".  The offline outbox sets it.  A synthetic rejection
    // here would burn the outbox's retry budget without touching the network
    // and back the sync off to minutes, which is precisely wrong when the
    // link has just come back.  Letting it through also gives the response's
    // success interceptor the chance to clear a stale unreachable flag.
    if (options.extra['bypassQueue'] == true) {
      options.extra['noRetry'] = true;
      handler.next(options);
      return;
    }

    if (_queue.isServerReachable) {
      handler.next(options);
    } else {
      ServerStatusManager.markError();

      // Callers that opt out of the queue (see ApiService._noQueue) are the
      // ones the user is actively waiting on -- page content, the shelf's
      // list reads, a settings write that a list read is waiting behind --
      // and every one of them has a cache or a default to fall back on.  They
      // have to fail now rather than sit here until the safety timeout fires.
      // Also mark them noRetry: retrying a request we already know cannot
      // succeed only delays the error.
      if (options.extra['noQueue'] == true) {
        options.extra['noRetry'] = true;
        handler.reject(
          DioException(
            requestOptions: options,
            // Deliberately generic: this path is shared by page content, the
            // shelf list reads and `setUserSetting`.  It is only ever read in
            // logs (the callers classify an unreachable failure into the
            // Offline state and never show the raw text), so it has to
            // describe the *kind* of failure, not guess which request it was.
            error: 'Offline: request opted out of the queue (noQueue)',
            type: DioExceptionType.connectionError,
          ),
        );
        return;
      }

      if (_isTermFormFetch(options)) {
        if (_hasQueuedTermForm) {
          handler.reject(
            DioException(
              requestOptions: options,
              error: 'Term form fetch dropped (connection issue)',
              type: DioExceptionType.connectionError,
            ),
          );
          return;
        }
        _hasQueuedTermForm = true;
        unawaited(
          _queue
              .enqueue(_dio, options)
              .then(
                (response) {
                  handler.resolve(response);
                },
                onError: (error) {
                  handler.reject(error as DioException);
                },
              ),
        );
      } else {
        unawaited(
          _queue
              .enqueue(_dio, options)
              .then(
                (response) => handler.resolve(response),
                onError: (error) => handler.reject(error as DioException),
              ),
        );
      }
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // The server answered and only the session needs a re-login: never
    // treat this as the server being down.
    if (err.error is ServerLoginRequiredException) {
      return handler.next(err);
    }

    // 队列自己的重放失败了：直接把失败交回调用方，不要再扣进队列。
    // 队列在发之前就把这条从 _queue 和签名表里摘掉了，调用方的 completer
    // 也即将收到这个错误 —— 再排一次就是在调用方已经收到失败之后再执行一遍。
    if (err.requestOptions.extra[ApiRequestQueue.extraFromQueue] == true) {
      return handler.next(err);
    }

    // Outbox traffic owns its own retry, so hand the real failure straight
    // back instead of parking it.  Skipping the health probe below also
    // matters: it is an extra round trip per attempt, and this path runs on
    // every retry for as long as the link is down.  The reachability flag
    // still gets updated -- `_addStatusInterceptor` runs after this one and
    // marks the error itself.
    if (err.requestOptions.extra['bypassQueue'] == true) {
      err.requestOptions.extra['noRetry'] = true;
      return handler.next(err);
    }

    final baseUrl = err.requestOptions.baseUrl;
    final health = baseUrl.isEmpty
        ? null
        : await ServerHealthService.check(baseUrl);

    if (health == null || health.ok || health.requiresLogin) {
      handler.next(err);
    } else {
      _queue.markServerUnreachable();
      ServerStatusManager.markError();

      // Same opt-out on the error path: a request that opted out of the queue
      // must surface its failure to the caller, not be parked here.
      if (err.requestOptions.extra['noQueue'] == true) {
        err.requestOptions.extra['noRetry'] = true;
        handler.next(err);
        return;
      }

      if (_isTermFormFetch(err.requestOptions)) {
        if (_hasQueuedTermForm) {
          handler.reject(
            DioException(
              requestOptions: err.requestOptions,
              error: 'Term form fetch dropped (connection issue)',
              type: DioExceptionType.connectionError,
            ),
          );
          return;
        }
        _hasQueuedTermForm = true;
        unawaited(
          _queue
              .enqueue(_dio, err.requestOptions)
              .then(
                (response) {
                  handler.resolve(response);
                },
                onError: (error) {
                  handler.reject(error as DioException);
                },
              ),
        );
      } else {
        unawaited(
          _queue
              .enqueue(_dio, err.requestOptions)
              .then(
                (response) => handler.resolve(response),
                onError: (error) => handler.reject(error as DioException),
              ),
        );
      }
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    handler.next(response);
  }
}
