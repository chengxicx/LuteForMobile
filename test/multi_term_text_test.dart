// 多词选区拼词：词间空格必须留下，只裁剪首尾、折叠连续空白。
//
// 背景（真机反馈）：EPUB 书长按拖选 `roll off`，词卡里显示成 `rolloff`。
// EPUB 阅读页不给空白 token 建 span，选区的 payload 里只有词，没有词间
// 空格；`reader_screen` 直接 `join()` 就把两个词粘在一起。这里锁住修复后的
// 契约：拼接保留空格、折叠连续空白、不改动词内字符（连字符/撇号/U+200B）、
// 中文与日文不凭空插空格；EPUB 路径按 order 闭区间从页面 token 流补齐。
//
// 运行：flutter test test/multi_term_text_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/utils/term_selection.dart';

/// Lute 的 token：空格、标点也是独立 item（wordId 为空）。
TextItem _token(String text, {required int order, int? wordId}) => TextItem(
  text: text,
  statusClass: wordId == null ? '' : 'status0',
  wordId: wordId,
  sentenceId: 0,
  paragraphId: 0,
  isStartOfSentence: order == 0,
  order: order,
  langId: 1,
);

/// 一页的 token 流：英文词与词之间有一个真实的空白 token。
List<TextItem> _englishPage() => [
  _token('roll', order: 0, wordId: 1),
  _token(' ', order: 1),
  _token('off', order: 2, wordId: 2),
];

void main() {
  test('英文双词选区保留词间空格（经典文本页）', () {
    expect(buildMultiTermText(_englishPage()), 'roll off');
  });

  test('三词短语逐段保真', () {
    final page = [
      _token('as', order: 0, wordId: 1),
      _token(' ', order: 1),
      _token('soon', order: 2, wordId: 2),
      _token(' ', order: 3),
      _token('as', order: 4, wordId: 3),
    ];
    expect(buildMultiTermText(page), 'as soon as');
  });

  test('连字符与撇号留在词里，缩进空白只裁剪/折叠', () {
    final page = [
      _token('  ', order: 0),
      _token("well-known", order: 1, wordId: 1),
      _token(' ', order: 2),
      _token("don't", order: 3, wordId: 2),
      _token('   ', order: 4),
    ];
    expect(buildMultiTermText(page), "well-known don't");
  });

  test('词内的零宽空格（U+200B）仍按显示文本剥掉', () {
    final page = [
      _token('まし\u200Bた', order: 0, wordId: 1),
      _token('よ\u200Bむ', order: 1, wordId: 2),
    ];
    expect(buildMultiTermText(page), 'ましたよむ');
  });

  test('中文/日文选区没有空白 token：不插入多余空格', () {
    expect(
      buildMultiTermText([
        _token('中华', order: 0, wordId: 1),
        _token('人民', order: 1, wordId: 2),
      ]),
      '中华人民',
    );
    expect(
      buildMultiTermText([
        _token('食べ', order: 0, wordId: 1),
        _token('ます', order: 1, wordId: 2),
      ]),
      '食べます',
    );
  });

  test('EPUB：payload 缺空白 token 时按 order 区间从页面 token 流补齐', () {
    final page = _englishPage();
    // 页面只回传两个词 span 的 payload（空白 token 没有 span）。
    final payloads = {
      0: _token('roll', order: 0, wordId: 1),
      2: _token('off', order: 2, wordId: 2),
    };
    final selected = selectionItemsInOrderRange(
      pageItems: page,
      payloadsByOrder: payloads,
    );

    expect(selected.map((item) => item.order).toList(), [0, 1, 2]);
    expect(buildMultiTermText(selected), 'roll off');
  });

  test('EPUB：span 的 data-order 是 token 下标 ×1000 + piece，需整除还原', () {
    expect(tokenIndexForSpanOrder(144000, usesPieceShift: true), 144);
    expect(tokenIndexForSpanOrder(146000, usesPieceShift: true), 146);
    // 一个 token 被行内标签切成两块：落在同一个 token 下标。
    expect(tokenIndexForSpanOrder(144001, usesPieceShift: true), 144);
    // 旧离线包仍是纯 token 下标，原样使用。
    expect(tokenIndexForSpanOrder(145, usesPieceShift: false), 145);
  });

  test('EPUB：×1000 的 payload 也按 token 区间补齐，空格不丢', () {
    final page = [
      _token('roll', order: 144, wordId: 1),
      _token(' ', order: 145),
      _token('off', order: 146, wordId: 2),
    ];
    // 页面回传的是 span 的 data-order（token 下标 ×1000）。
    final payloads = {
      tokenIndexForSpanOrder(144000, usesPieceShift: true):
          _token('roll', order: 144, wordId: 1),
      tokenIndexForSpanOrder(146000, usesPieceShift: true):
          _token('off', order: 146, wordId: 2),
    };

    final selected = selectionItemsInOrderRange(
      pageItems: page,
      payloadsByOrder: payloads,
    );

    expect(buildMultiTermText(selected), 'roll off');
  });

  test('EPUB：模型里没有的 order 仍用 payload 兜底', () {
    final selected = selectionItemsInOrderRange(
      pageItems: const [],
      payloadsByOrder: {
        0: _token('roll', order: 0, wordId: 1),
        1: _token('off', order: 1, wordId: 2),
      },
    );
    expect(selected.map((item) => item.text).toList(), ['roll', 'off']);
  });
}
