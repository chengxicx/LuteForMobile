import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_request_queue.dart';
import 'package:song_mobile/core/network/queued_dio_interceptor.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';

// 冷启动 302 波（Leaf5C 实测 + nginx 日志）：
//
// 启动瞬间健康检查还没成功，app 认为服务端不可达，于是没带 noQueue 的请求被
// 扣进 ApiRequestQueue。一秒后网络确认可达，队列一次性重放它们 —— 但重放用的
// 是**裸 `Dio()`**，没有任何拦截器：
//
//   * 不带 session cookie → 服务端每条都 302 到 /login（nginx 里 199/233/241/
//     245 字节的 302，与直接 curl 的登录跳转逐字节一致）；
//   * 裸 Dio 默认 followRedirects: true → 它跟着跳到登录页，把**登录页 HTML
//     当成 200 的正文**交回调用方。屏幕于是显示成空列表（单词页「No terms
//     found」）而不是报错，看起来像数据被清空了。
//
// 于是同一秒里 nginx 能看到两种请求交错：带 cookie 的直发请求 200，不带
// cookie 的重放 302。这里锁住修复：重放必须走 app 自己的那条 Dio。
void main() {
  late ApiRequestQueue queue;

  setUp(() {
    ServerStatusManager.setReachable(true);
    queue = ApiRequestQueue();
  });

  tearDown(() {
    queue.dispose();
    ServerStatusManager.setReachable(true);
  });

  /// 构造一条和 app 里同构的 Dio：队列拦截器在前，session 拦截器在后
  /// （顺序与 ApiService 一致），适配器在最底下记录真正发出去的请求。
  ({Dio dio, _RecordingAdapter adapter}) buildDio(
    String url, {
    bool fail = false,
  }) {
    final adapter = _RecordingAdapter(fail: fail);
    final dio = Dio(BaseOptions(baseUrl: url))..httpClientAdapter = adapter;
    dio.interceptors.add(QueuedDioInterceptor(queue, dio));
    // 冒充 ApiService._addSessionInterceptor：真实实现从 SessionManager 取
    // cookie，这里只要证明「重放经过了这条拦截器」即可。
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Cookie'] = 'session=abc';
          return handler.next(options);
        },
      ),
    );
    return (dio: dio, adapter: adapter);
  }

  /// 把队列推进「离线」，然后发一个请求 —— 它会被扣住，返回的 future 在
  /// 重放之前不会完成。（故意不是 async：async 会把 future await 掉。）
  Future<Response<String>> startQueuedRequest(Dio dio) {
    ServerStatusManager.markError();
    return dio.post<String>('/term/datatables', data: {'draw': 1});
  }

  /// 等队列这一轮处理完，否则 markSuccess 触发的 flush 会被 `_isProcessing`
  /// 挡在门外，测试就挂在 await 上。
  Future<void> waitIdle() async {
    for (var i = 0; i < 100 && queue.isProcessing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('重放必须走 app 自己的 Dio:带 session cookie,不是裸 Dio', () async {
    // 每个用例换一个端口：队列是单例，且 initialize() 在同 URL 时会直接
    // 返回（连监听都不会重新注册）。
    final built = buildDio('http://127.0.0.1:1');
    queue.initialize('http://127.0.0.1:1', built.dio);

    final future = startQueuedRequest(built.dio);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await waitIdle();

    expect(built.adapter.seen, isEmpty, reason: '离线期间请求该被扣住，不发出去');

    ServerStatusManager.markSuccess();
    final response = await future;

    expect(response.statusCode, 200);
    expect(built.adapter.seen, hasLength(1));
    expect(
      built.adapter.seen.single.headers['Cookie'],
      'session=abc',
      reason:
          '重放走了裸 Dio：服务端会因缺 session cookie 返回 302 → /login，'
          '而裸 Dio 会跟随跳转把登录页当成 200 返回，屏幕显示成空列表',
    );
  });

  test('重放成功后请求被摘干净,不会二次执行', () async {
    final built = buildDio('http://127.0.0.1:2');
    queue.initialize('http://127.0.0.1:2', built.dio);

    final future = startQueuedRequest(built.dio);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await waitIdle();

    ServerStatusManager.markSuccess();
    await future;
    await waitIdle();

    expect(built.adapter.seen, hasLength(1), reason: '一个 POST 只能落地一次');
    expect(queue.queueLength, 0);
  });

  test('重放失败不会被再扣回队列(调用方已经收到失败了)', () async {
    final built = buildDio('http://127.0.0.1:3', fail: true);
    queue.initialize('http://127.0.0.1:3', built.dio);

    final future = startQueuedRequest(built.dio);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await waitIdle();

    ServerStatusManager.markSuccess();
    await expectLater(future, throwsA(isA<DioException>()));
    await waitIdle();

    expect(
      queue.queueLength,
      0,
      reason: '队列在重放前就把它摘掉了，调用方也已经拿到失败，不能再排一次',
    );
  });
}

/// 记录每条真正发出去的请求，不发网络。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.fail = false});

  final bool fail;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    if (fail) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'offline',
      );
    }
    return ResponseBody.fromString(
      '{"data":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
