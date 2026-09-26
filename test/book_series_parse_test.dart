import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/models/book.dart';

/// Book Set（服务端 tag 聚合）解析的回归测试。
///
/// 背景：服务端把某个 tag 下的多本书聚合成**一行**返回
/// （`lute/book/datatables.py` 的 `series_branch`）：
/// `BkID = NULL`、`BkTitle = tag 名`、`BookType = 'series'`、
/// `PageCount = 书数`。客户端原先不知道这种行，`Book.fromJson` 的容错转换
/// 把 NULL 变成 0，于是它被当成一本 id=0 的普通书，点开就去请求
/// `/book/edit/0`，阅读器一片空白。
///
/// 这里用服务端真实的行字段（含 NULL 值）来锁住解析行为，
/// 特别是 toJson → fromJson 的缓存往返 —— 聚合行字段一旦没落进缓存，
/// 读回来 `isSeries` 就会变回 false，聚合行会以「幽灵书」的形态复活。
void main() {
  /// 服务端 `series_branch` 产出的聚合行（字段名与 SQL 别名一一对应）。
  Map<String, dynamic> seriesRow({
    Object? seriesStatsPending = '3,7',
    int bookCount = 12,
    int readCount = 5,
    String tag = 'ai-story',
    String langName = 'Japanese',
    int langId = 4,
  }) {
    return {
      'BkID': null,
      'LgID': langId,
      'LgName': langName,
      'BkTitle': tag,
      'PageNum': 1,
      'PageCount': bookCount,
      'LastOpenedDate': '2026-09-20 10:11:12',
      'BkArchived': 0,
      'TagList': tag,
      'WordCount': 98765,
      'DistinctCount': 4321,
      'UnknownCount': 1200,
      'UnknownPercent': 27,
      'NewWordPercent': 3,
      'StatusDistribution': null,
      'IsCompleted': readCount >= bookCount ? 1 : 0,
      // 服务端对空集合会走 `CASE WHEN bookcount <= 0 THEN 0`，这里同样防除零。
      'ProgressPercent': bookCount <= 0
          ? 0
          : (readCount * 100 / bookCount).floor(),
      'BookType': 'series',
      'SeriesTag': tag,
      'SeriesBookCount': bookCount,
      'SeriesReadCount': readCount,
      'SeriesStatsPending': seriesStatsPending,
    };
  }

  /// 服务端 `_flat_base_sql` 产出的普通书行。
  Map<String, dynamic> flatRow({
    int id = 42,
    int pageNum = 3,
    int pageCount = 10,
  }) {
    return {
      'BkID': id,
      'LgID': 4,
      'LgName': 'Japanese',
      'BkTitle': 'Episode 1',
      'PageNum': pageNum,
      'PageCount': pageCount,
      'LastOpenedDate': '2026-09-19 08:00:00',
      'BkArchived': 0,
      'TagList': 'ai-story, sci-fi',
      'WordCount': 1234,
      'DistinctCount': 400,
      'UnknownPercent': 12,
      'StatusDistribution': '{"0":10,"1":20,"2":0,"3":0,"4":0,"5":0,"98":0,"99":370}',
      'IsCompleted': 0,
      'BookType': '',
      'SeriesTag': null,
      'SeriesBookCount': null,
      'SeriesReadCount': null,
      'SeriesStatsPending': null,
    };
  }

  group('series aggregate row', () {
    test('is recognised as a series even though BkID is NULL', () {
      final book = Book.fromJson(seriesRow());

      expect(book.isSeries, isTrue, reason: 'BookType=series 必须被识别');
      expect(book.id, 0, reason: 'NULL BkID 容错后为 0，这是服务端事实');
      expect(book.title, 'ai-story');
      expect(book.seriesTag, 'ai-story');
    });

    test('exposes the server-side book/read counts', () {
      final book = Book.fromJson(seriesRow(bookCount: 12, readCount: 5));

      expect(book.seriesCount, 12);
      expect(book.seriesReadCount, 5);
      // PageCount 对聚合行而言是「书数」，不是页数。
      expect(book.totalPages, 12);
    });

    test('percent means "share of books read", not a page ratio', () {
      final book = Book.fromJson(seriesRow(bookCount: 12, readCount: 5));

      // 5/12 = 41.67% → 42。若误用页数公式会得到 1/12 = 8%。
      expect(
        book.percent,
        42,
        reason: '聚合行进度必须是已读/总书数，不能套用 PageNum/PageCount',
      );
    });

    test('percent is clamped and safe for an empty set', () {
      expect(Book.fromJson(seriesRow(bookCount: 0, readCount: 0)).percent, 0);
      // 服务端理论上不会给出 readCount > bookCount，但缓存/脏数据可能。
      expect(
        Book.fromJson(seriesRow(bookCount: 3, readCount: 9)).percent,
        100,
      );
    });

    test('progress badge shows read/total books', () {
      final book = Book.fromJson(seriesRow(bookCount: 12, readCount: 5));
      expect(book.pageProgress, '5/12 books');
    });

    test('parses SeriesStatsPending id list', () {
      expect(Book.fromJson(seriesRow(seriesStatsPending: '3,7')).seriesStatsPending, [3, 7]);
      expect(Book.fromJson(seriesRow(seriesStatsPending: '9')).seriesStatsPending, [9]);
      // 无待补算书时服务端给 NULL，不能退化成 [0]。
      expect(Book.fromJson(seriesRow(seriesStatsPending: null)).seriesStatsPending, isNull);
      expect(Book.fromJson(seriesRow(seriesStatsPending: '')).seriesStatsPending, isNull);
      expect(Book.fromJson(seriesRow(seriesStatsPending: ' , ')).seriesStatsPending, isNull);
    });

    test('hasTermCount is true even without a status distribution', () {
      final book = Book.fromJson(seriesRow());
      // 服务端不聚合状态分布，但 DistinctCount 是有效的。
      expect(book.statusDistribution, isNull);
      expect(book.hasStats, isFalse);
      expect(
        book.hasTermCount,
        isTrue,
        reason: '聚合卡片应显示词数，而不是「— terms」',
      );
      expect(book.distinctTerms, 4321);
    });
  });

  group('flat book row', () {
    test('is not mistaken for a series', () {
      final book = Book.fromJson(flatRow());
      expect(book.isSeries, isFalse);
      expect(book.id, 42);
      expect(book.seriesTag, isNull);
    });

    test('keeps the page-based percent', () {
      final book = Book.fromJson(flatRow(pageNum: 3, pageCount: 10));
      expect(book.percent, 30);
      expect(book.pageProgress, '3/10');
    });

    test('a manga book type is not a series', () {
      final row = flatRow()..['BookType'] = 'manga';
      expect(Book.fromJson(row).isSeries, isFalse);
    });
  });

  group('cache round-trip', () {
    test('series fields survive toJson -> fromJson', () {
      final original = Book.fromJson(seriesRow(bookCount: 7, readCount: 2));
      final restored = Book.fromJson(original.toJson());

      expect(
        restored.isSeries,
        isTrue,
        reason: '聚合行字段没落缓存的话，读回来会变成 id=0 的幽灵书',
      );
      expect(restored.seriesTag, 'ai-story');
      expect(restored.seriesCount, 7);
      expect(restored.seriesReadCount, 2);
      expect(restored.percent, 29); // 2/7 = 28.57% → 29
      expect(restored.title, 'ai-story');
      expect(restored.seriesStatsPending, [3, 7]);
    });

    test('a flat book stays flat after the round-trip', () {
      final original = Book.fromJson(flatRow());
      final restored = Book.fromJson(original.toJson());

      expect(restored.isSeries, isFalse);
      expect(restored.id, 42);
      expect(restored.percent, original.percent);
    });
  });
}
