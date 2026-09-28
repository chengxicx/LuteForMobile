import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/providers/books_provider.dart';

/// 「断网时不要把 DioException 原文拍在屏幕上」的回归测试。
///
/// 背景（Leaf5C 实测）：断网打开书架，屏幕上是一坨
///
/// ```
/// DioException [connection error]: null
/// Error: Offline: request expired after 30s in the queue
/// ```
///
/// 用户读到的信息量是零，而且会以为自己弄坏了什么。分类的判据是
/// `ServerStatusManager.isReachable`：拦截器在判定服务端不可达时会
/// `markError()`（见 `QueuedDioInterceptor.onRequest/onError`），所以标志为假
/// 就等于「根本没连上」。健康探测通过时 `onError` 走 `handler.next`，标志不动 ——
/// 于是「服务器真的回了错」仍然会如实显示原文。
void main() {
  group('classifyLoadFailure', () {
    test('连不上服务端 → 不显示错误原文，改标记为离线', () {
      final (message, offline) = BooksNotifier.classifyLoadFailure(
        error: Exception('DioException [connection error]: null'),
        serverReachable: false,
      );
      expect(
        message,
        isNull,
        reason: '离线是可自愈的状态，不该把 DioException 原文给用户看',
      );
      expect(offline, isTrue);
    });

    test('服务端可达但请求失败 → 显示原文，且不算离线', () {
      final (message, offline) = BooksNotifier.classifyLoadFailure(
        error: Exception('500 Internal Server Error'),
        serverReachable: true,
      );
      expect(message, contains('500 Internal Server Error'));
      expect(
        offline,
        isFalse,
        reason: '服务器回了错不是离线，否则界面会显示 Offline 页并等一个永远不会来的自动恢复',
      );
    });

    test('errorMessage 与 isOffline 不能同时有效', () {
      // 两者同时成立会让 books_screen 在错误页和 Offline 页之间打架
      // （_buildBody 先判 errorMessage，Offline 分支永远轮不到）。
      for (final reachable in [true, false]) {
        final (message, offline) = BooksNotifier.classifyLoadFailure(
          error: Exception('boom'),
          serverReachable: reachable,
        );
        expect(
          message == null || !offline,
          isTrue,
          reason: 'reachable=$reachable 时两者同时有效',
        );
      }
    });

    test('判据就是 serverReachable，不看错误类型', () {
      // 同一个错误对象，两种可达性下结论必须相反 —— 这正是
      // _recordLoadFailure 把判断交给调用点的原因。
      final error = Exception('DioException [connection error]: null');
      expect(
        BooksNotifier.classifyLoadFailure(
          error: error,
          serverReachable: true,
        ).$1,
        isNotNull,
      );
      expect(
        BooksNotifier.classifyLoadFailure(
          error: error,
          serverReachable: false,
        ).$1,
        isNull,
      );
    });
  });
}
