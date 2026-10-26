import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/features/reader/models/series_chapter.dart';

/// 章末导航（上一章 / 下一章 / 目录）的数据侧回归测试。
///
/// 背景：EPUB 导入是**一章一本书**，同一册的章节靠 book tag 聚成一个
/// Book Set。服务端 `lute/book/series.py: series_neighbours` 算好前后章，
/// 写进 `read/index.html` 的两个隐藏 input；"回到书集" 链接的 href 携带
/// tag。手机端原先完全不读这些字段，于是读到章末没有任何去处。
///
/// 这里锁住三件事：
///   1. 能从阅读页 HTML 里认出系列（含三种"没有系列"的形态）；
///   2. 章节书的书名前缀（`书名 05 - 章节名`）能剥成章节名；
///   3. 章节顺序按数字自然序，与服务端 prev/next 的排序一致。
void main() {
  group('series extraction', () {
    String metadata({
      String next = '',
      String prev = '',
      String? seriesHref,
    }) =>
        '''
<html><body>
<div id="rendering_controls" style="display: none">
  <pre>
    page_num: <input id="page_num" value="1">
    page_count: <input id="page_count" value="1">
    series_next_book: <input id="series_next_book_id" value="$next">
    series_prev_book: <input id="series_prev_book_id" value="$prev">
  </pre>
</div>
${seriesHref == null ? '' : '<div id="reading-end-controls"><a class="end-icon-btn toc" href="$seriesHref" title="x">toc</a></div>'}
</body></html>
''';

    test('picks up the neighbour ids and the set tag', () {
      final page = HtmlParser().parsePage(
        '<div id="thetext"></div>',
        metadata(
          next: '927',
          prev: '925',
          seriesHref: '/book/series/The%20Wife%20Between%20Us',
        ),
        bookId: 926,
      );

      expect(page.seriesNextBookId, 927);
      expect(page.seriesPrevBookId, 925);
      // The tag is URL-encoded in the href, and must come back readable:
      // it is the key of the chapter-list lookup.
      expect(page.seriesTag, 'The Wife Between Us');
    });

    test('first chapter of a set has no previous id', () {
      final page = HtmlParser().parsePage(
        '<div id="thetext"></div>',
        metadata(next: '881', seriesHref: '/book/series/Carrie'),
        bookId: 880,
      );

      expect(page.seriesPrevBookId, isNull);
      expect(page.seriesNextBookId, 881);
      expect(page.seriesTag, 'Carrie');
    });

    test('a standalone book reports no series at all', () {
      final page = HtmlParser().parsePage(
        '<div id="thetext"></div>',
        metadata(),
        bookId: 1,
      );

      expect(page.seriesTag, isNull);
      expect(page.seriesPrevBookId, isNull);
      expect(page.seriesNextBookId, isNull);
    });

    test('an empty href and an id of 0 are not values', () {
      // The server writes '' for "no neighbour" and would never write 0, but
      // a hand-edited page or a future template change must not turn into a
      // button that navigates to book 0.
      final page = HtmlParser().parsePage(
        '<div id="thetext"></div>',
        metadata(next: '0', prev: ' ', seriesHref: '/book/series/'),
        bookId: 1,
      );

      expect(page.seriesNextBookId, isNull);
      expect(page.seriesPrevBookId, isNull);
      expect(page.seriesTag, isNull);
    });
  });

  group('chapter titles', () {
    test('strips the import prefix', () {
      expect(
        chapterDisplayTitle('The Wife Between Us 05 - Prologue'),
        'Prologue',
      );
      expect(
        chapterDisplayTitle('The Wife Between Us 48 - Chapter Forty-One'),
        'Chapter Forty-One',
      );
    });

    test('keeps a " - " that belongs to the chapter title', () {
      // Only the first " NN - " is the prefix; a real chapter title may
      // contain its own dash and must survive.
      expect(
        chapterDisplayTitle('Carrie 07 - Part One - The Gym'),
        'Part One - The Gym',
      );
    });

    test('leaves a title that has no prefix alone', () {
      expect(chapterDisplayTitle('实用日语2-26课文'), '实用日语2-26课文');
      expect(chapterDisplayTitle('Prologue'), 'Prologue');
      expect(chapterDisplayTitle('  Chapter 3  '), 'Chapter 3');
    });
  });

  group('chapter order', () {
    Book book(int id, String title) => Book.fromJson({
      'BkID': id,
      'BkTitle': title,
      'LgName': 'English',
      'LgID': 1,
      'PageNum': 1,
      'PageCount': 1,
      'TagList': 'Carrie',
    });

    test('sorts digit runs as numbers, not as text', () {
      // The EPUB import zero-pads (`05`), so strings would sort correctly
      // there too -- a hand-made set does not pad, and then "Ep 10" would
      // come before "Ep 2" and the reader's numbers would disagree with
      // the server's prev/next.
      final chapters = buildSeriesChapters([
        book(3, 'Podcast Ep 10 - Ten'),
        book(1, 'Podcast Ep 2 - Two'),
        book(2, 'Podcast Ep 1 - One'),
      ]);

      expect(chapters.map((c) => c.bookId).toList(), [2, 1, 3]);
      expect(chapters.map((c) => c.position).toList(), [1, 2, 3]);
      expect(chapters.map((c) => c.title).toList(), [
        'One',
        'Two',
        'Ten',
      ]);
    });

    test('numbers a zero-padded set in its printed order', () {
      final chapters = buildSeriesChapters([
        book(2, 'Carrie 02 - Chapter Two'),
        book(1, 'Carrie 01 - Chapter One'),
        book(10, 'Carrie 10 - Chapter Ten'),
      ]);

      expect(chapters.map((c) => c.title).toList(), [
        'Chapter One',
        'Chapter Two',
        'Chapter Ten',
      ]);
      expect(chapters.last.position, 3);
    });
  });
}
