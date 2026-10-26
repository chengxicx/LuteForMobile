// 新建词落地后，页面要不要跟着重载。
//
// 背景（真机反馈）：双词选中弹出词卡，关闭后整页重新加载 —— 转圈、回顶。
//
// 根因有两层：
//   1. 双词选中生成的是一个**新词**（termId == null）。关闭词卡（X 键默认
//      「保存并关闭」）走 onSave，那里写着 `reloadPage(forceFresh: true)`：
//      清空整本书的页面缓存 + 绕过缓存重新拉当前页，`isLoading` 让整页换成
//      转圈。可是 `saveTerm` 对新词只是**入队**（outbox），服务器此刻根本
//      没有这个词，重拉回来的 HTML 一模一样 —— 纯亏。
//   2. 真正需要刷页的时机是「新词同步成功」（handleOutboxSynced）。那时页面
//      的标记结构变了：跨词的两段 span 合成一段，而 `_mergePageStatuses`
//      只按位置改 statusClass，表达不了结构变化，只能整页替换 —— 静默替换。
//
// 这里锁住第 2 步的判断：只有新词确实出现在当前页上时才值得刷，否则每次翻到
// 别的页都会白拉一次网络。
//
// 运行：flutter test test/term_create_page_refresh_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/providers/reader_provider.dart';

TextItem _item(String text, {required int order, int paragraphId = 0}) =>
    TextItem(
      text: text,
      statusClass: 'status0',
      wordId: order + 1,
      langId: 1,
      sentenceId: 0,
      paragraphId: paragraphId,
      isStartOfSentence: order == 0,
      order: order,
    );

PageData _page(List<Paragraph> paragraphs) => PageData(
  bookId: 1,
  currentPage: 1,
  pageCount: 2,
  paragraphs: paragraphs,
);

void main() {
  test('跨词选出来的新词算「在这一页上」', () {
    // 双词选中：两个相邻的 span，拼起来才是新词。
    final page = _page([
      Paragraph(
        id: 0,
        textItems: [_item('携', order: 0), _item('帯', order: 1)],
      ),
    ]);

    expect(pageShowsText(page, '携帯'), isTrue);
  });

  test('空白不影响判断（词是 span 拼的，页是逐段拼的）', () {
    final page = _page([
      Paragraph(id: 0, textItems: [_item('申し訳', order: 0)]),
      Paragraph(id: 1, textItems: [_item('ありません', order: 1)]),
    ]);

    expect(pageShowsText(page, '申し訳 ありません'), isTrue);
    expect(pageShowsText(page, '申し訳\nありません'), isTrue);
  });

  test('不在这一页的词不值得刷页', () {
    final page = _page([
      Paragraph(id: 0, textItems: [_item('携帯', order: 0)]),
    ]);

    expect(pageShowsText(page, '電源'), isFalse);
  });

  test('空词不刷页', () {
    final page = _page([
      Paragraph(id: 0, textItems: [_item('携帯', order: 0)]),
    ]);

    expect(pageShowsText(page, ''), isFalse);
    expect(pageShowsText(page, '   '), isFalse);
  });
}
