import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_request_queue.dart';

// 断网时这个队列会把请求扣在内存里，而它的 completer 只在重放成功/失败时
// 才完成 —— 也就是离线期间**永远不会完成**。调用方全都写成 `await ... catch`，
// 于是「永远不完成」就等于「那个屏永远停在 loading」：书集详情页原先就是这么
// 挂住的，书架的 _isLoadingBooks / _isLoadingFromNetwork 也这么卡死过（它们
// 在 finally 里复位，await 不返回就永不复位）。
//
// 这里锁住三条性质：
//   1. 排队有上限，到点判失败而不是无限等；
//   2. 到点后必须把请求从队列和签名表里摘干净 —— 留在队列里的话，网络恢复时
//      它会被真的发出去，而调用方早就收到失败了，一个 POST 就被执行两次；
//   3. 签名清掉之后，同样的请求还能重新入队，而不是拿到那个已死的 completer。
void main() {
  final queue = ApiRequestQueue();

  setUp(() {
    queue.dispose();
    // 空的 serverUrl 让 _processQueue 直接返回：请求只能靠上限结束，
    // 于是测的是上限本身，而不是重放。
    queue.initialize('', Dio());
    queue.requestDeadline = const Duration(milliseconds: 60);
  });

  tearDown(() => queue.dispose());

  RequestOptions options({String path = '/books/active'}) =>
      RequestOptions(path: path, baseUrl: 'http://example.invalid/');

  test('排队的请求到点会失败,不会永远挂着', () async {
    await expectLater(queue.enqueue(Dio(), options()), throwsExpiry);
  });

  test('到点后请求被摘出队列,不会在网络恢复时被重放成第二次写入', () async {
    final future = queue.enqueue(Dio(), options());
    expect(queue.queueLength, 1);

    await expectLater(future, throwsExpiry);

    expect(queue.queueLength, 0);
  });

  test('到点后同样的请求可以重新入队(签名已清,不会拿到死掉的 completer)', () async {
    await expectLater(queue.enqueue(Dio(), options()), throwsExpiry);

    final second = queue.enqueue(Dio(), options());
    expect(queue.queueLength, 1, reason: '应该是一次全新的排队');
    await expectLater(second, throwsExpiry);
  });

  test('排队期间重复提交同一个请求只留一个', () async {
    final a = queue.enqueue(Dio(), options());
    final b = queue.enqueue(Dio(), options());
    expect(queue.queueLength, 1);

    await expectLater(a, throwsExpiry);
    await expectLater(b, throwsExpiry);
  });

  test('不同请求各占一个队列位', () async {
    final a = queue.enqueue(Dio(), options(path: '/books/active'));
    final b = queue.enqueue(Dio(), options(path: '/books/archived'));
    expect(queue.queueLength, 2);

    await expectLater(a, throwsExpiry);
    await expectLater(b, throwsExpiry);
    expect(queue.queueLength, 0);
  });
}

/// 上限到期时报的错：连接类错误，调用方的 catch 分支按「暂时性失败」处理。
final Matcher throwsExpiry = throwsA(
  isA<DioException>().having(
    (e) => e.type,
    'type',
    DioExceptionType.connectionError,
  ),
);
