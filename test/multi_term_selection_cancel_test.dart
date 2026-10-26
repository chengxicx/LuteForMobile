// 多词选中的收尾契约。
//
// 背景（真机反馈）：长按拖选两个词弹出词卡后，点「取消」回来整页像卡死 ——
// 点词不弹卡、手势翻页、点按钮翻页全都不动，只能杀进程。
//
// 根因：多选的状态分住在两层。
//   * TextDisplay 的 `_selectionStartItem` —— 非空时 `_handleTap` 直接 return，
//     之后所有点击都被吞掉；
//   * ReaderScreen 的 `_isMultiTermSelecting` —— 为 true 时 `_canSwipePages`
//     恒 false，翻页全灭。
// 这两处都只在「长按正常结束」时清（onLongPressEnd）。而长按被系统取消时
// （路由变化、手势被抢、弹出词卡自己抢焦点）onLongPressEnd **不会来**，
// 于是两个标记一起烂在原地，页面就"卡死"了。
//
// 所以契约是：取消路径必须也把两层状态清干净，并且取消之后点击照常生效。
//
// 运行：flutter test test/multi_term_selection_cancel_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/widgets/text_display.dart';

TextItem _item(String text, {required int order}) => TextItem(
  text: text,
  statusClass: 'status0',
  wordId: order + 1,
  langId: 1,
  sentenceId: 0,
  paragraphId: 0,
  isStartOfSentence: order == 0,
  order: order,
);

/// 一行三个词，够拖一次跨选。
List<Paragraph> _paragraphs() => [
  Paragraph(
    id: 0,
    textItems: [
      _item('あい', order: 0),
      _item('うえ', order: 1),
      _item('おか', order: 2),
    ],
  ),
];

/// 记录 TextDisplay 抛给外层的每一次回调。
class _Recorder {
  int starts = 0;
  int cancels = 0;
  final List<List<TextItem>> completes = [];
  final List<String> taps = [];
}

Widget _host(_Recorder recorder) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 600,
      child: TextDisplay(
        paragraphs: _paragraphs(),
        onTap: (item, _) => recorder.taps.add(item.text),
        onMultiTermSelectionStart: () => recorder.starts++,
        onMultiTermSelectionComplete: (items) => recorder.completes.add(items),
        onMultiTermSelectionCancel: () => recorder.cancels++,
      ),
    ),
  ),
);

void main() {
  testWidgets('长按拖选后正常松手：把选中的词交出去', (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_host(recorder));

    final first = tester.getCenter(find.text('あい'));
    final second = tester.getCenter(find.text('うえ'));

    final gesture = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(recorder.starts, 1, reason: '长按一落下就该进入多选');

    await gesture.moveTo(second);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(recorder.completes, hasLength(1));
    expect(
      recorder.completes.single.map((item) => item.text).toList(),
      ['あい', 'うえ'],
    );
    expect(recorder.cancels, 0);
  });

  testWidgets('长按被取消：两层状态都复位，随后点击照常生效', (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_host(recorder));

    final first = tester.getCenter(find.text('あい'));
    final second = tester.getCenter(find.text('うえ'));

    final gesture = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(second);
    await tester.pump();

    // 手势被系统收走 —— 真机上就是弹出词卡/路由变化打断了长按。
    await gesture.cancel();
    await tester.pump();

    expect(recorder.cancels, 1, reason: '取消必须上报，外层才能复位多选标记');
    expect(recorder.completes, isEmpty, reason: '取消不该当成选完');

    // 没有复位时 `_handleTap` 会在这里 return，点击就永远收不到。
    await tester.tapAt(first);
    await tester.pump(const Duration(milliseconds: 400));

    expect(recorder.taps, ['あい'], reason: '取消后点击必须还能到达单词');
  });

  testWidgets('取消之后还能重新选一次', (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_host(recorder));

    final first = tester.getCenter(find.text('あい'));
    final second = tester.getCenter(find.text('うえ'));

    final abandoned = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await abandoned.cancel();
    await tester.pump();

    final retry = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await retry.moveTo(second);
    await tester.pump();
    await retry.up();
    await tester.pump();

    expect(recorder.starts, 2);
    expect(recorder.cancels, 1);
    expect(
      recorder.completes.single.map((item) => item.text).toList(),
      ['あい', 'うえ'],
    );
  });
}
