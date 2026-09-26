import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/providers/books_provider.dart';

/// 「书架把服务器切换误判成清缓存」的回归测试。
///
/// 背景：设置（含 serverUrl）是异步从 SharedPreferences 读出来的，而
/// `BooksNotifier.build()` 的首帧拿到的是 `Settings.defaultSettings()` 里的
/// **空 URL**。如果把这个空串当成「上一次的服务器」记下来，设置加载完成后的
/// 真实 URL 就会被判成「换了服务器」，触发 `_onServerChanged()` 把书目缓存
/// 清空 —— 真机表现是每次启动都白跑一次全量网络同步，断网时书架直接空白
/// （缓存刚被自己清掉，实测在 OnePlus 11 上复现）。
void main() {
  group('resolveServerUrlChange', () {
    test('首帧的空 URL 不算「换了服务器」', () {
      // build() 首帧：previous 是 null（或防御性地是空串），current 还是空。
      expect(BooksNotifier.resolveServerUrlChange(null, ''), (null, false));
      expect(BooksNotifier.resolveServerUrlChange('', ''), ('', false));
    });

    test('设置加载完成、第一次拿到真实 URL 时只记录，不算切换', () {
      // 这是回归的关键一步：空 URL -> 真实 URL **不能**触发清缓存。
      expect(
        BooksNotifier.resolveServerUrlChange(null, 'https://a.example'),
        ('https://a.example', false),
        reason: '首帧空 URL 被当成旧服务器，会把书目缓存清掉',
      );
      expect(
        BooksNotifier.resolveServerUrlChange('', 'https://a.example'),
        ('https://a.example', false),
      );
    });

    test('设置还没读出来时不动作，也不会丢掉已知的旧 URL', () {
      // current 为空 = 这一帧没有可比较的信息，previous 必须原样保留，
      // 否则后续拿到真实 URL 时又会被当成「第一次」而漏掉真实的服务器切换。
      expect(
        BooksNotifier.resolveServerUrlChange('https://a.example', ''),
        ('https://a.example', false),
      );
    });

    test('两个真实 URL 之间的切换才算换服务器', () {
      expect(
        BooksNotifier.resolveServerUrlChange(
          'https://a.example',
          'https://b.example',
        ),
        ('https://b.example', true),
      );
    });

    test('URL 没变时不做任何事', () {
      expect(
        BooksNotifier.resolveServerUrlChange(
          'https://a.example',
          'https://a.example',
        ),
        ('https://a.example', false),
      );
    });

    test('清空 URL 后再设一个新 URL，仍应识别为切换', () {
      // 用户先清空（previous 保留 a），再填 b —— 这是真实的服务器切换。
      final (afterClear, changedOnClear) =
          BooksNotifier.resolveServerUrlChange('https://a.example', '');
      expect(changedOnClear, isFalse);
      expect(
        BooksNotifier.resolveServerUrlChange(afterClear, 'https://b.example'),
        ('https://b.example', true),
      );
    });
  });
}
