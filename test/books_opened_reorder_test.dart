import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/features/books/providers/books_provider.dart';

/// 「书架的『最新阅读』重排在阅读时后台完成，进 Books 页不再跳动」的
/// 回归测试。
///
/// 背景：服务端书单默认按 LastOpenedDate 降序返回（datatables.py），而
/// `/read/start_reading` 会把刚读的书排到最前。这个变化以前要等下次进
/// 书架的网络同步才落地——先渲染缓存旧序、同步回来再跳成新序，用户每次
/// 从阅读页切回 Books 都看着列表重排一次。修法是打开书时本地预演这个
/// 重排（BooksNotifier.notifyBookOpened → reorderAfterOpened）。
void main() {
  Book book(
    int id,
    String? lastRead, {
    String bookType = '',
    String? seriesTag,
  }) {
    return Book(
      id: id,
      title: 'Book $id',
      language: 'ja',
      totalPages: 10,
      currentPage: 1,
      percent: 10,
      wordCount: 100,
      distinctTerms: null,
      unknownPct: null,
      statusDistribution: null,
      lastRead: lastRead,
      bookType: bookType,
      seriesTag: seriesTag,
    );
  }

  /// 模拟一次服务端同步后的书单：从未打开的书排最前，其余按最近阅读降序
  /// （datatables.py 的 `LastOpenedDate is null desc, LastOpenedDate desc`）。
  final serverOrder = [
    book(9, null), // 从未打开，排最前
    book(8, null),
    book(1, '2026-10-01 08:05:03.000000'), // 最近读的
    book(2, '2026-09-20 10:00:00.000000'),
    book(3, '2026-09-01 10:00:00.000000'),
  ];

  group('reorderAfterOpened', () {
    test('打开已读过的书 → 插到「已打开」组最前，从未打开的仍在其上', () {
      final result = BooksNotifier.reorderAfterOpened(
        serverOrder,
        3,
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.id).toList(), [9, 8, 3, 1, 2]);
    });

    test('打开从未打开过的书 → 补上时间戳，落到从未打开组之后', () {
      final result = BooksNotifier.reorderAfterOpened(
        serverOrder,
        8,
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.id).toList(), [9, 8, 1, 2, 3]);
      expect(
        result.firstWhere((b) => b.id == 8).lastRead,
        '2026-10-11 01:00:00.000000',
        reason: 'lastRead 为 null 的书即使位置凑巧不变也要补时间戳，'
            '否则它会一直显示 "Never" 直到下次同步',
      );
    });

    test('已在目标位置且有 lastRead → 返回同一实例，不刷状态不重写缓存', () {
      final result = BooksNotifier.reorderAfterOpened(
        serverOrder,
        1,
        '2026-10-11 01:00:00.000000',
      );

      expect(identical(result, serverOrder), isTrue);
    });

    test('书不在列表里 → 原样返回', () {
      final result = BooksNotifier.reorderAfterOpened(
        serverOrder,
        999,
        '2026-10-11 01:00:00.000000',
      );

      expect(identical(result, serverOrder), isTrue);
    });

    test('聚合行（id 为 0）与带 seriesTag 的行都不参与重排', () {
      final withSeries = [
        book(0, '2026-10-01 08:05:03.000000', bookType: 'series'),
        ...serverOrder,
      ];

      expect(
        identical(
          BooksNotifier.reorderAfterOpened(withSeries, 0, 'x'),
          withSeries,
        ),
        isTrue,
      );
      // seriesTag 非空的普通行同样按聚合行对待。
      final tagged = [book(7, null, seriesTag: 'yojimbo')];
      expect(
        identical(
          BooksNotifier.reorderAfterOpened(tagged, 7, 'x'),
          tagged,
        ),
        isTrue,
      );
    });

    test('列表全是从未打开的书 → 被打开的书落到最后', () {
      final fresh = [book(5, null), book(6, null)];

      final result = BooksNotifier.reorderAfterOpened(
        fresh,
        6,
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.id).toList(), [5, 6]);
      expect(result.last.lastRead, isNotNull);
    });

    test('重排不打乱其他书的相对顺序', () {
      final result = BooksNotifier.reorderAfterOpened(
        serverOrder,
        2,
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.id).toList(), [9, 8, 2, 1, 3]);
    });
  });

  group('reorderSeriesAfterOpened（Book Set 成员书 → 聚合行预排）', () {
    // 服务端书单顶部常见形态：聚合行在前（其 LastOpenedDate = 成员书最大值），
    // 成员书本身不在顶层书单里。读某个 Book Set 下的书时它的聚合行会跳顶。
    Book series(String tag, String? lastRead, {int? langId}) => book(
      0,
      lastRead,
      bookType: 'series',
      seriesTag: tag,
    ).copyWith(langId: langId);

    test('读到的成员书 tag 命中聚合行 → 该聚合行跳到「已打开」组最前并补时间戳', () {
      final shelf = [
        series('zonghe', '2026-09-21 10:00:00.000000'),
        series('ai-story', '2026-10-01 08:05:03.000000'),
        series('shiyong', null),
      ];

      final result = BooksNotifier.reorderSeriesAfterOpened(
        shelf,
        {'ai-story', 'yojimbo'},
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.seriesTag).toList(), [
        'ai-story',
        'zonghe',
        'shiyong',
      ]);
      expect(result.first.lastRead, '2026-10-11 01:00:00.000000');
    });

    test('从未打开过的聚合行也会被顶上来（插到「已打开」组最前）', () {
      final shelf = [
        series('ai-story', '2026-10-01 08:05:03.000000'),
        series('shiyong', null),
      ];

      final result = BooksNotifier.reorderSeriesAfterOpened(
        shelf,
        {'shiyong'},
        '2026-10-11 01:00:00.000000',
      );

      expect(result.map((b) => b.seriesTag).toList(), [
        'shiyong',
        'ai-story',
      ]);
      expect(result.first.lastRead, '2026-10-11 01:00:00.000000');
    });

    test('tag 不命中任何聚合行 → 原样返回', () {
      final shelf = [
        series('zonghe', '2026-09-21 10:00:00.000000'),
      ];

      expect(
        identical(
          BooksNotifier.reorderSeriesAfterOpened(
            shelf,
            {'no-such-tag'},
            'x',
          ),
          shelf,
        ),
        isTrue,
      );
    });

    test('已在目标位置且有 lastRead → 原样返回', () {
      final shelf = [
        series('ai-story', '2026-10-01 08:05:03.000000'),
        series('zonghe', '2026-09-21 10:00:00.000000'),
      ];

      expect(
        identical(
          BooksNotifier.reorderSeriesAfterOpened(
            shelf,
            {'ai-story'},
            '2026-10-11 01:00:00.000000',
          ),
          shelf,
        ),
        isTrue,
      );
    });

    test('同一 tag 按语言出多行时优先 langId 匹配的行', () {
      final enRow = series('ai-story', '2026-09-15 10:00:00.000000')
          .copyWith(langId: 3);
      final jpRow = series('ai-story', '2026-09-30 10:00:00.000000')
          .copyWith(langId: 7);

      final result = BooksNotifier.reorderSeriesAfterOpened(
        [enRow, jpRow],
        {'ai-story'},
        '2026-10-11 01:00:00.000000',
        langId: 7,
      );

      expect(result.first.langId, 7);
      expect(result.last.langId, 3);
    });
  });

  group('Book.lastReadStamp', () {
    // 黄金值实测自部署服务端 /book/datatables/active 的真实返回：
    // LastOpenedDate = '2026-10-10 18:08:05.055979'（SQLite 原始串，naive UTC）。
    test('与服务端 jsonify 的格式逐字符一致', () {
      final utc = DateTime.utc(2026, 10, 10, 18, 8, 5, 0, 55979);
      expect(Book.lastReadStamp(utc), '2026-10-10 18:08:05.055979');
    });

    test('个位日期与时间补零，微秒固定 6 位', () {
      final utc = DateTime.utc(2026, 1, 5, 3, 7, 9);
      expect(Book.lastReadStamp(utc), '2026-01-05 03:07:09.000000');
    });

    test('now() 产物可被 DateTime.parse 读回，且与服务端形状一致', () {
      final stamp = Book.lastReadStampNow();
      expect(
        stamp,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$')),
      );
      // 卡片的相对时间靠这个解析；解析失败会显示空白。
      expect(DateTime.parse(stamp), isA<DateTime>());
    });
  });

  group('lastRead 显示的时区口径（naive UTC 不能按本地解析）', () {
    // 2026-10-11 实测：服务端串是 naive UTC，DateTime.parse 按本地时区
    // 装入，UTC+8 的设备上刚读完的书显示 "8 hours ago"。
    Book bookWithLastRead(String? lastRead) => Book(
          id: 1,
          title: 't',
          language: 'ja',
          totalPages: 1,
          currentPage: 1,
          percent: 0,
          wordCount: 0,
          distinctTerms: null,
          unknownPct: null,
          statusDistribution: null,
          lastRead: lastRead,
        );

    test('8 小时前（UTC）显示 "8 hours ago"，不随时区翻倍', () {
      final stamp = Book.lastReadStamp(
        DateTime.now().toUtc().subtract(const Duration(hours: 8)),
      );
      expect(bookWithLastRead(stamp).formattedLastRead, '8 hours ago');
    });

    test('刚刚的 stamp 显示 "just now"', () {
      expect(bookWithLastRead(Book.lastReadStampNow()).formattedLastRead,
          'just now');
    });

    test('精确时间按 UTC 解释后转本地，不再差一个时区', () {
      final local = DateTime.utc(2026, 10, 10, 18, 8, 5, 0, 55979).toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
        bookWithLastRead('2026-10-10 18:08:05.055979').formattedLastReadExact,
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
      );
    });

    test('带 Z 后缀的串不受重解释影响', () {
      final local = DateTime.utc(2026, 10, 10, 18, 8, 5).toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
        bookWithLastRead('2026-10-10T18:08:05.000Z').formattedLastReadExact,
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
      );
    });
  });
}
