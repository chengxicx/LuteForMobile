import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/status_overlay.dart';
import 'package:song_mobile/features/reader/models/manga_page.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/pdf_page.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';

// overlay 是「地铁里改状态」这条链路上最关键的一环:服务端并不知道本地还没同步
// 的改动,所以它返回的每一份数据都是过期的。没有 overlay,_mergePageStatuses
// 会在一次后台刷新后把颜色换回旧的 —— 用户看到的就是「刚点的东西自己弹回去了」。
void main() {
  group('pendingStatusByTermId', () {
    test('只收 term 类意图,page 类不掺进来', () {
      final pending = pendingStatusByTermId([
        TermEditIntent(termId: 1, status: '3', seq: 0),
        PageDoneIntent(
          bookId: 1,
          pageNum: 1,
          markRead: true,
          markKnown: true,
          seq: 1,
        ),
        TermCreateIntent(langId: 1, text: '犬', formData: const {}, seq: 2),
      ]);

      expect(pending, {1: '3'});
    });

    test('失败的意图仍然算数', () {
      // 失败 = 服务端 4xx 或重试超预算,但用户确实按下了那一下。把颜色撤回去
      // 等于在用户眼皮底下把他的编辑删掉,还把「需要处理」这件事藏起来。
      final pending = pendingStatusByTermId([
        TermEditIntent(termId: 1, status: '99', seq: 0, failed: true),
      ]);

      expect(pending, {1: '99'});
    });
  });

  group('applyPendingStatuses', () {
    test('把段落里的词涂成待同步的状态', () {
      final page = _textPage(bookId: 5, pageNum: 1, wordIds: [10, 11, 12]);

      final overlaid = applyPendingStatuses(page, {11: '99'});

      expect(_statusOf(overlaid, 0), 'status0');
      expect(_statusOf(overlaid, 1), 'status99');
      expect(_statusOf(overlaid, 2), 'status0');
    });

    test('没有待同步内容时返回同一个对象(不白复制)', () {
      // 每次翻页都会跑一遍 overlay,而绝大多数页面没有任何待同步内容 —— 这
      // 条保证的是热路径上不产生垃圾。
      final page = _textPage(bookId: 5, pageNum: 1, wordIds: [10]);

      expect(identical(applyPendingStatuses(page, const {}), page), isTrue);
    });

    test('值没变时不重建那个 item(identical)', () {
      final page = _textPage(bookId: 5, pageNum: 1, wordIds: [10]);
      final original = page.paragraphs.first.textItems.first;

      final overlaid = applyPendingStatuses(page, {10: '0'});

      expect(
        identical(overlaid.paragraphs.first.textItems.first, original),
        isTrue,
      );
    });

    test('wordId 为 null 的片段(标点、空白)不受影响', () {
      final page = PageData(
        bookId: 5,
        currentPage: 1,
        pageCount: 3,
        paragraphs: [
          Paragraph(
            id: 1,
            textItems: [
              _item('猫', wordId: 10, status: 'status0'),
              _item('、', wordId: null, status: ''),
              _item('犬', wordId: 11, status: 'status0'),
            ],
          ),
        ],
      );

      final overlaid = applyPendingStatuses(page, {10: '99', 11: '99'});
      final items = overlaid.paragraphs.first.textItems;

      expect(items[0].statusClass, 'status99');
      expect(items[1].statusClass, '', reason: '没有 wordId 就没人认领它');
      expect(items[2].statusClass, 'status99');
    });

    test('漫画页的行内词也能涂到(MangaBlock 没有 copyWith,是重建的)', () {
      final page = PageData(
        bookId: 5,
        currentPage: 1,
        pageCount: 3,
        paragraphs: const [],
        mangaPage: MangaPageData(
          imagePath: '/static/a.jpg',
          imgWidth: 100,
          imgHeight: 200,
          pageNum: 1,
          blocks: [
            MangaBlock(
              left: 1,
              top: 2,
              width: 3,
              height: 4,
              lineItems: [
                [_item('猫', wordId: 10, status: 'status0')],
              ],
            ),
          ],
        ),
      );

      final overlaid = applyPendingStatuses(page, {10: '99'});
      final block = overlaid.mangaPage!.blocks.first;

      expect(block.lineItems.first.first.statusClass, 'status99');
      expect(block.left, 1, reason: '重建时要保留坐标');
      expect(block.height, 4);
    });

    test('PDF 页的词也能涂到(PdfWord 同样是重建的)', () {
      final page = PageData(
        bookId: 5,
        currentPage: 1,
        pageCount: 3,
        paragraphs: const [],
        pdfPage: PdfPageData(
          pdfPath: '/static/a.pdf',
          pageWidth: 100,
          pageHeight: 200,
          pageNum: 1,
          words: [
            PdfWord(
              left: 1,
              top: 2,
              width: 3,
              height: 4,
              items: [_item('猫', wordId: 10, status: 'status0')],
            ),
          ],
        ),
      );

      final overlaid = applyPendingStatuses(page, {10: '99'});

      expect(
        overlaid.pdfPage!.words.first.items.first.statusClass,
        'status99',
      );
      expect(overlaid.pdfPage!.words.first.width, 3);
    });
  });

  group('All Known 的页级标记', () {
    test('hasPendingPageKnown 认页,别的页不算', () {
      final intents = [
        PageDoneIntent(
          bookId: 5,
          pageNum: 12,
          markRead: false,
          markKnown: true,
          seq: 0,
        ),
      ];

      expect(hasPendingPageKnown(intents, 5, 12), isTrue);
      expect(hasPendingPageKnown(intents, 5, 13), isFalse);
      expect(hasPendingPageKnown(intents, 6, 12), isFalse);
    });

    test('只 markRead 不算(它不改任何词的状态)', () {
      final intents = [
        PageDoneIntent(
          bookId: 5,
          pageNum: 12,
          markRead: true,
          markKnown: false,
          seq: 0,
        ),
      ];

      expect(hasPendingPageKnown(intents, 5, 12), isFalse);
    });

    test('unknownWordStatuses 只挑 status0 —— 与服务端 set_unknowns_to_known 同口径', () {
      // 服务端那个函数筛的是 ti.term.status == 0,所以用户显式设成 1..5/98 的
      // 词不会被 All Known 动到。这里必须完全一致,否则本地显示会和同步后的
      // 服务端结果不一样。
      final page = PageData(
        bookId: 5,
        currentPage: 1,
        pageCount: 3,
        paragraphs: [
          Paragraph(
            id: 1,
            textItems: [
              _item('未', wordId: 10, status: 'status0'),
              _item('已', wordId: 11, status: 'status3'),
              _item('忽', wordId: 12, status: 'status98'),
              _item('知', wordId: 13, status: 'status99'),
            ],
          ),
        ],
      );

      expect(unknownWordStatuses(page), {10: '99'});
    });

    test('applyPageKnown 把未知词涂成已知,已标记的不动', () {
      final page = _textPage(bookId: 5, pageNum: 1, wordIds: [10, 11]);

      final known = applyPageKnown(page);

      expect(_statusOf(known, 0), 'status99');
      expect(_statusOf(known, 1), 'status99');
    });

    test('已经全是已知时返回同一个对象', () {
      final page = PageData(
        bookId: 5,
        currentPage: 1,
        pageCount: 3,
        paragraphs: [
          Paragraph(
            id: 1,
            textItems: [_item('猫', wordId: 10, status: 'status99')],
          ),
        ],
      );

      expect(identical(applyPageKnown(page), page), isTrue);
    });

    test('第二次 applyPageKnown 是幂等的', () {
      final page = _textPage(bookId: 5, pageNum: 1, wordIds: [10, 11]);

      final once = applyPageKnown(page);
      final twice = applyPageKnown(once);

      expect(identical(twice, once), isTrue);
    });
  });
}

// --- helpers ---

TextItem _item(String text, {required int? wordId, required String status}) =>
    TextItem(
      text: text,
      statusClass: status,
      wordId: wordId,
      sentenceId: 1,
      paragraphId: 1,
      isStartOfSentence: true,
      order: 0,
      langId: 42,
    );

PageData _textPage({
  required int bookId,
  required int pageNum,
  required List<int> wordIds,
}) => PageData(
  bookId: bookId,
  currentPage: pageNum,
  pageCount: 3,
  paragraphs: [
    Paragraph(
      id: 1,
      textItems: [
        for (final wordId in wordIds)
          _item('w$wordId', wordId: wordId, status: 'status0'),
      ],
    ),
  ],
);

String _statusOf(PageData page, int index) =>
    page.paragraphs.first.textItems[index].statusClass;
