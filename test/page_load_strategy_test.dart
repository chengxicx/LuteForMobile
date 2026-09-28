import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/services/page_load_strategy.dart';

// 纯函数,零 harness —— 这正是把它从 ReaderNotifier 里抽出来的原因。
void main() {
  group('resolvePageLoadStrategy', () {
    test('显式页码:请求了具体页就走 explicitPage,不管本地记着什么', () {
      // 用户点了页码/点了翻页,或冷启动带着 currentBookPage —— 这是明确的
      // 意图,不能被「本地记住的页」顶掉。
      expect(
        resolvePageLoadStrategy(
          requestedPage: 9,
          localPage: 3,
          localPageCached: true,
          serverReachable: true,
        ),
        PageLoadStrategy.explicitPage,
      );
    });

    test('显式页码:离线也仍然是 explicitPage(缓存命中由下游处理)', () {
      expect(
        resolvePageLoadStrategy(
          requestedPage: 9,
          localPage: null,
          localPageCached: false,
          serverReachable: false,
        ),
        PageLoadStrategy.explicitPage,
      );
    });

    test('无记录 + 在线:交给服务端决定起读页', () {
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: null,
          localPageCached: false,
          serverReachable: true,
        ),
        PageLoadStrategy.initialNetwork,
      );
    });

    test('无记录 + 离线:快速失败,不要干等', () {
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: null,
          localPageCached: false,
          serverReachable: false,
        ),
        PageLoadStrategy.offlineNoCache,
      );
    });

    test('有记录且已缓存 + 在线:本地优先,服务端后台校正', () {
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: 7,
          localPageCached: true,
          serverReachable: true,
        ),
        PageLoadStrategy.localCacheThenRefresh,
      );
    });

    test('有记录且已缓存 + 离线:这才是地铁场景,必须能开', () {
      // 整个离线读改造的核心断言:断网时翻开昨天读过的书,应该直接
      // 出正文,而不是报错。
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: 7,
          localPageCached: true,
          serverReachable: false,
        ),
        PageLoadStrategy.localCacheThenRefresh,
      );
    });

    test('有记录但未缓存 + 在线:仍然要那一页,不让服务端另挑', () {
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: 7,
          localPageCached: false,
          serverReachable: true,
        ),
        PageLoadStrategy.recordNetwork,
      );
    });

    test('有记录但未缓存 + 离线:无米下锅,快速失败', () {
      // 页码记录本身不构成可用内容 —— 页被淘汰后离线只能如实报错,
      // 而不是拿一个必然失败的页码去撞网络。
      expect(
        resolvePageLoadStrategy(
          requestedPage: null,
          localPage: 7,
          localPageCached: false,
          serverReachable: false,
        ),
        PageLoadStrategy.offlineNoCache,
      );
    });
  });
}
