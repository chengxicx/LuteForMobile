import 'dart:async';
import 'package:dio/dio.dart';
import '../../shared/providers/server_status_provider.dart';
import '../../core/logger/api_logger.dart';
import '../../core/services/server_health_service.dart';

class QueuedRequest {
  final String signature;
  final RequestOptions options;
  final Completer<Response> completer;
  final DateTime enqueuedAt;
  final Dio dio;

  /// 到点就把这个请求判失败，见 [ApiRequestQueue._requestDeadline]。
  Timer? deadline;

  QueuedRequest({
    required this.signature,
    required this.options,
    required this.completer,
    required this.enqueuedAt,
    required this.dio,
  });
}

class ApiRequestQueue {
  static final ApiRequestQueue _instance = ApiRequestQueue._internal();
  factory ApiRequestQueue() => _instance;
  ApiRequestQueue._internal();

  /// 一个排队请求最多被扣多久。
  ///
  /// 队列的初衷是「离线时先把请求攒着，等网络回来再发」，但它的 completer
  /// 只在重放成功/失败时才完成 —— 也就是说离线期间**永远不会完成**。而调用方
  /// 全都写成 `await ... catch`，于是：
  ///
  /// - 依赖它完成才更新界面的屏永久停在 loading（书集详情页原先就是这样）；
  /// - 把它放在 `finally` 之前复位的标志永久卡在 true，之后再也不刷新
  ///   （书架的 `_isLoadingBooks` / `_isLoadingFromNetwork`）。
  ///
  /// 所以排队必须有上限。到点判失败而不是无限等待：调用方的 catch 分支本来
  /// 就准备好了，而这个队列本来就只在内存里（进程一死全丢），「一定会送到」
  /// 从来不是它能给的承诺 —— 需要那个承诺的写路径归 outbox 管。
  static const Duration _defaultRequestDeadline = Duration(seconds: 30);

  /// 排队上限，见 [_defaultRequestDeadline]。
  ///
  /// 做成实例字段而不是常量，只是为了测试能把它调短：否则验证「到点判失败」
  /// 要等满 30 秒。
  Duration requestDeadline = _defaultRequestDeadline;

  /// 轮询 tick。有请求在等时用它，保证网络一恢复就尽快重放。
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// `RequestOptions.extra` 键：标记「这一条是队列自己在重放」。
  ///
  /// 重放走的是 app 自己的那条 Dio（见 [enqueue] 的 `dio` 参数），所以它会
  /// 重新经过 [QueuedDioInterceptor] —— 不标记的话拦截器会把它再扣回队列，
  /// 变成自我循环，而且调用方的 completer 早就完成了，等于同一个 POST 被执行
  /// 两次。
  static const String extraFromQueue = 'fromQueue';

  /// 空队列时探针的节流间隔，见 [_processQueue]。
  static const Duration _idleProbeInterval = Duration(seconds: 5);

  final List<QueuedRequest> _queue = [];
  final Map<String, Completer<Response>> _pendingSignatures = {};
  Timer? _pollTimer;
  DateTime? _lastProbeAt;
  bool _isProcessing = false;
  bool _isServerReachable = true;
  String? _serverUrl;
  String _basicAuthUser = '';
  String _basicAuthPassword = '';

  bool get isServerReachable => _isServerReachable;

  String get basicAuthUser => _basicAuthUser;
  String get basicAuthPassword => _basicAuthPassword;

  void markServerUnreachable() {
    _isServerReachable = false;
  }

  void initialize(
    String serverUrl,
    Dio dio, {
    String basicAuthUser = '',
    String basicAuthPassword = '',
  }) {
    if (_serverUrl != null && _serverUrl == serverUrl) {
      return;
    }

    _serverUrl = serverUrl;
    _basicAuthUser = basicAuthUser;
    _basicAuthPassword = basicAuthPassword;
    _isServerReachable = ServerStatusManager.isReachable;

    ServerStatusManager.addListener(_onServerStatusChanged);

    // 启动时若已经知道服务器不可达，轮询必须自己起：否则没有任何东西会再
    // 去探一次，这个标志就永远回不到 true。
    if (!_isServerReachable) {
      _startPolling();
    }
  }

  void _onServerStatusChanged() {
    _isServerReachable = ServerStatusManager.isReachable;

    if (_isServerReachable) {
      _stopPolling();
    } else {
      // 恢复必须是自驱的：下面 [_processQueue] 里的探针是唯一会把这个标志
      // 置回 true 的地方，而页面内容和 outbox 都绕开了这个队列 —— 离线时
      // 不会再有别的东西来问第二次。
      _startPolling();
    }

    unawaited(_processQueue());
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _processQueue());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void dispose() {
    ServerStatusManager.removeListener(_onServerStatusChanged);
    _stopPolling();
    _lastProbeAt = null;
    for (final request in _queue) {
      request.deadline?.cancel();
      request.deadline = null;
      if (!request.completer.isCompleted) {
        request.completer.completeError(Exception('Queue disposed'));
      }
    }
    _queue.clear();
    _pendingSignatures.clear();
    _isProcessing = false;
  }

  String _computeSignature(RequestOptions options) {
    final method = options.method;
    final url = options.uri.toString();
    final body = options.data?.toString() ?? '';
    return '$method:$url:$body';
  }

  /// 把请求扣进队列，等网络恢复后重放。
  ///
  /// [dio] 是**重放时真正使用**的客户端，必须是 app 自己那条（带
  /// `_addSessionInterceptor` 的），不能是裸的 `Dio()`：裸 Dio 既不带 session
  /// cookie，又会默认跟随 302 到 `/login`，于是重放既拿不到数据、也不报错，
  /// 而是把登录页当成 200 的正文返回 —— 屏幕显示成空列表。见
  /// [QueuedDioInterceptor._dio]。
  Future<Response> enqueue(Dio dio, RequestOptions options) async {
    final signature = _computeSignature(options);

    if (_pendingSignatures.containsKey(signature)) {
      final existingCompleter = _pendingSignatures[signature]!;
      return existingCompleter.future;
    }

    final completer = Completer<Response>();
    _pendingSignatures[signature] = completer;

    final queuedRequest = QueuedRequest(
      signature: signature,
      options: options,
      completer: completer,
      enqueuedAt: DateTime.now(),
      dio: dio,
    );

    // 上限。到点必须先从队列里摘掉再判失败：留在队列里的话，等网络恢复
    // 重放时它会真的发出去，而调用方早就收到失败了 —— 一个 POST 就这样
    // 被执行两次。签名也要一并清掉，否则后续同样的请求会拿到这个已经死掉的
    // completer，永远等下去。
    queuedRequest.deadline = Timer(requestDeadline, () {
      if (completer.isCompleted) return;

      _queue.remove(queuedRequest);
      _pendingSignatures.remove(signature);

      ApiLogger.logRequest(
        'enqueue',
        details:
            '${options.uri} expired after ${requestDeadline.inSeconds}s '
            'in the queue',
      );

      completer.completeError(
        DioException(
          requestOptions: options,
          error:
              'Offline: request expired after ${requestDeadline.inSeconds}s '
              'in the queue',
          type: DioExceptionType.connectionError,
        ),
      );
    });

    _queue.add(queuedRequest);
    ApiLogger.logRequest(
      'enqueue',
      details: '${options.uri}, queueLength=${_queue.length}',
    );

    unawaited(_processQueue());

    return completer.future;
  }

  Future<void> _processQueue() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) return;

    if (_isProcessing) return;

    if (_isServerReachable) {
      if (_queue.isEmpty) return;
    } else {
      // 探针不能被「队列为空」挡住。它是唯一调用
      // `ServerStatusManager.setReachable(true)` 的地方，而页面内容和 outbox
      // 都绕开了这个队列 —— 「不可达 + 队列为空」正是断网后 app 的常态，
      // 在这里 return 会让整个 app 在网络回来之后仍然停在离线的样子。
      final now = DateTime.now();
      final last = _lastProbeAt;
      // 没人在等就没有延迟要保：空转时把探针放慢，免得离线干耗电。
      if (_queue.isEmpty &&
          last != null &&
          now.difference(last) < _idleProbeInterval) {
        return;
      }
      _lastProbeAt = now;
    }

    _isProcessing = true;

    if (!_isServerReachable) {
      ApiLogger.logRequest(
        '_processQueue',
        details: 'server unreachable, probing...',
      );
      final health = await ServerHealthService.check(_serverUrl!);
      if (health.ok || health.requiresLogin) {
        // requiresLogin: the server answers, so requests may proceed and
        // surface the login error instead of stalling in the queue.
        _isServerReachable = true;
        ServerStatusManager.setReachable(true);
        _stopPolling();
        ApiLogger.logRequest(
          '_processQueue',
          details: 'server recovered, resuming queue',
        );
      } else {
        ServerStatusManager.markError();
        _startPolling();
        ApiLogger.logRequest(
          '_processQueue',
          details: 'server still unreachable',
        );
      }
    }

    if (_isServerReachable && _queue.isNotEmpty) {
      final requestsToProcess = List<QueuedRequest>.from(_queue);
      _queue.clear();

      ApiLogger.logRequest(
        '_processQueue',
        details: 'processing ${requestsToProcess.length} requests',
      );

      for (final request in requestsToProcess) {
        _pendingSignatures.remove(request.signature);

        // 已经在发了，就把上限交给这次 fetch 自己的超时：发送中的请求不该
        // 因为排队计时到期而被判失败，那会变成「不知道到底有没有落地」。
        request.deadline?.cancel();
        request.deadline = null;

        try {
          // 标记成重放：这条会重新经过 [QueuedDioInterceptor]，不标记就会被
          // 再扣回队列。
          request.options.extra[extraFromQueue] = true;
          final response = await request.dio.fetch(request.options);
          if (!request.completer.isCompleted) {
            request.completer.complete(response);
          }
        } catch (e) {
          if (!request.completer.isCompleted) {
            request.completer.completeError(e);
          }
        }
      }
    }

    _isProcessing = false;
  }

  int get queueLength => _queue.length;
  bool get isProcessing => _isProcessing;
}
