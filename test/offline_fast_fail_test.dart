import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_request_queue.dart';
import 'package:song_mobile/core/network/queued_dio_interceptor.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';

// 断网时**第一次**请求归谁管，决定了用户要等多久才看到 Offline：
//
//   * 没带 noQueue 的请求会被 ApiRequestQueue 扣在内存里。队列的 completer
//     只在重放成功/失败时才完成，而离线期间没有重放 —— 等于永远不完成，只能
//     等 requestDeadline（30 秒）到点。用户看到的就是「转圈半分钟」。
//   * 带 noQueue 的请求在拦截器里就被合成拒绝，立刻失败。
//
// 书架的书目列表读（getActiveBooks / getArchivedBooks）和紧挨在它们前面的
// setUserSetting 现在都带 noQueue，所以书架断网是「秒进 Offline」而不是
// 「等 30 秒」。这里锁住这个区别，免得以后有人把 noQueue 摘掉而没人发现。
void main() {
  late ApiRequestQueue queue;
  late Dio dio;

  setUp(() {
    // 队列是单例，且 dispose() 不复位 _serverUrl —— 状态会跨用例留下，
    // 所以每个用例都显式把可达性摆到自己要的档位。
    ServerStatusManager.setReachable(true);

    queue = ApiRequestQueue();
    // 空 serverUrl 让 _processQueue 在门口就返回：排队的请求不会真的被发
    // 出去，于是测的是「上限本身」而不是重放。
    queue.initialize('', Dio());

    queue.markServerUnreachable();
    ServerStatusManager.setReachable(false);

    dio = Dio(BaseOptions(baseUrl: 'http://example.invalid/'));
    dio.interceptors.add(QueuedDioInterceptor(queue, dio));
  });

  tearDown(() {
    // 先摘监听再复位状态：否则 dispose 之后的那次通知还会打到队列上。
    queue.dispose();
    ServerStatusManager.setReachable(true);
  });

  test('带 noQueue 的请求在不可达时立刻失败,不占队列位', () async {
    // 上限放到 30 秒（和线上一样）：如果这个请求被扣进队列，它在 2 秒内
    // 不可能抛出任何东西 —— 那样下面的 timeout 就会失败，而不是靠计时抖动。
    queue.requestDeadline = const Duration(seconds: 30);

    final future = dio.post<String>(
      '/book/datatables/active',
      options: Options(extra: const {'noQueue': true}),
    );

    await expectLater(future, throwsA(isA<DioException>())).timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail(
        'noQueue 的请求被扣进队列了：它本该立刻失败，而不是等 requestDeadline',
      ),
    );

    expect(queue.queueLength, 0, reason: 'noQueue 的请求不该占队列位');
  });

  test('没带 noQueue 的请求会被扣进队列,只能等上限到点', () async {
    queue.requestDeadline = const Duration(milliseconds: 400);

    final future = dio.post<String>('/book/datatables/active');
    // 给拦截器一点时间跑完 onRequest 的入队分支。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(queue.queueLength, 1, reason: '普通请求该被排队，而不是立刻失败');

    // 必须 await 到上限：否则 tearDown 里 dispose 会用一个没人接的
    // completeError 结束它，变成未处理的异步错误。
    await expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (e) => e.error.toString(),
          'error',
          contains('expired after'),
        ),
      ),
    );
  });
}
