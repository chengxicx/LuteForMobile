import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/app_bar_layout.dart';

void main() {
  group('顶栏页码导航占位页数', () {
    test('页面数据还没到（0）时用书架的页数', () {
      // 打开书的一瞬间 pageData 还是 null：导航不该显示，但它要占的位置
      // 得按书的真实页数留好，否则首屏一到整排按钮会往左跳。
      expect(
        appBarReservedPageCount(pageCount: 0, bookPageCount: 2),
        equals(2),
      );
    });

    test('占位数据只有一页时也用书架的页数', () {
      expect(
        appBarReservedPageCount(pageCount: 1, bookPageCount: 341),
        equals(341),
      );
    });

    test('首屏到达后两处一致，宽度不变', () {
      expect(
        appBarReservedPageCount(pageCount: 341, bookPageCount: 341),
        equals(341),
      );
    });

    test('页面数据比书架新时以页面数据为准', () {
      // 书架缓存的 PageCount 可能过期（比如分页在别处改过）。
      expect(
        appBarReservedPageCount(pageCount: 12, bookPageCount: 2),
        equals(12),
      );
    });

    test('单页书两边都不显示导航', () {
      expect(
        appBarReservedPageCount(pageCount: 1, bookPageCount: 1),
        equals(1),
      );
      expect(
        appBarReservedPageCount(pageCount: 0, bookPageCount: 0),
        equals(0),
      );
    });
  });

  group('页面数据归属', () {
    test('同一本书才采信', () {
      expect(pageDataBelongsToBook(pageBookId: 42, bookId: 42), isTrue);
    });

    test('上一本书的残留不能采信', () {
      // 换书加载时 pageData 还是上本 30 页的书，新书只有 2 页 —— 采信它
      // 会按 30 页预留，加载完再缩回 2 页，箭头就往里跳。
      expect(pageDataBelongsToBook(pageBookId: 30, bookId: 42), isFalse);
    });

    test('没有页面数据自然不可信', () {
      expect(pageDataBelongsToBook(pageBookId: null, bookId: 42), isFalse);
    });

    test('书架数据缺失时退回页面数据', () {
      expect(pageDataBelongsToBook(pageBookId: 42, bookId: null), isTrue);
    });
  });
}
