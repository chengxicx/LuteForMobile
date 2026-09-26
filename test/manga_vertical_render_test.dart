// Manga 竖排块渲染与翻页契约测试。
//
// 竖排（vertical-rl）块必须逐字竖叠：每列一字宽、字保持直立、列从右往左排。
// 曾经的实现整词横排——「ちょっと」渲染成一条 4 字宽的横带，列宽达到字号的
// 数倍，溢出 OCR 框、大面积盖住旁边的画面，用户看到的就是「文字和漫画错位」。
//
// 显示时机与 web / mokuro 对齐：
//
//   1. 文字框默认隐藏，点框显示（点画面空白处收起，眼睛=全部显示）；
//   2. 竖排行按字拆格：整词的 Text 不存在，单字的 Text 各在其位；
//   3. 列序仍是 vertical-rl：第一行在最右，列内自上而下；
//   4. 点任何一个字，回调带的仍是整词的 TextItem（查词/高亮语义不变）；
//   5. 横排块不受影响：仍按整词渲染；
//   6. 翻页：点画面右 1/3 下一页、左 1/3 上一页、中间不翻；框被钉住时
//      第一下点击只收起；横向快滑翻页；缩放状态下不翻页。
//
// 运行：flutter test test/manga_vertical_render_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/manga_page.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/widgets/manga_page_view.dart';

TextItem _item(String text, {int order = 0}) => TextItem(
      text: text,
      statusClass: 'status0',
      wordId: 100 + order,
      sentenceId: 0,
      paragraphId: 0,
      isStartOfSentence: order == 0,
      order: order,
    );

MangaPageData _page() => MangaPageData(
      imagePath: '/static/manga/x/001.jpg',
      imgWidth: 1080,
      imgHeight: 1530,
      pageNum: 1,
      blocks: [
        MangaBlock(
          left: 10,
          top: 5,
          width: 30,
          height: 60,
          vertical: true,
          fontSizeCqw: 10,
          lineItems: [
            [_item('ちょっと', order: 0)],
            [_item('待ったー', order: 1), _item('！！', order: 2)],
          ],
        ),
        MangaBlock(
          left: 50,
          top: 5,
          width: 45,
          height: 10,
          vertical: false,
          fontSizeCqw: 5,
          lineItems: [
            [_item('いいのですか', order: 3)],
          ],
        ),
      ],
    );

Widget _host(
  MangaPageData page, {
  void Function(TextItem)? onTap,
  void Function(bool forward)? onTurnPage,
  bool revealAll = false,
  double height = 700,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: height,
        child: MangaPageView(
          manga: page,
          imageUrl: 'https://example.test/001.jpg',
          revealAll: revealAll,
          onTurnPage: onTurnPage,
          onTap: onTap == null ? null : (item, _) => onTap(item),
        ),
      ),
    ),
  );
}

/// 点第 [index] 个文字框（默认隐藏，点一下显示）。
Future<void> _reveal(WidgetTester tester, int index) async {
  await tester.tap(find.byKey(ValueKey('manga-block-$index')));
  await tester.pump();
}

void main() {
  testWidgets('文字框默认隐藏，点一下才显示；眼睛全开全关', (tester) async {
    await tester.pumpWidget(_host(_page()));

    // 默认什么都看不到：整词、单字都没有。
    expect(find.text('ちょっと'), findsNothing);
    expect(find.text('ち'), findsNothing);
    expect(find.text('いいのですか'), findsNothing);

    // 点竖排框 → 显示。
    await _reveal(tester, 0);
    expect(find.text('ち'), findsOneWidget);
    // 横排框仍未显示。
    expect(find.text('いいのですか'), findsNothing);

    // 眼睛全开（revealAll 是顶栏传进来的属性）。
    await tester.pumpWidget(_host(_page(), revealAll: true));
    await tester.pump();
    expect(find.text('ち'), findsOneWidget);
    expect(find.text('いいのですか'), findsOneWidget);

    // 眼睛全关：回到隐藏，钉住的框也一起收起。
    await tester.pumpWidget(_host(_page(), revealAll: false));
    await tester.pump();
    expect(find.text('ち'), findsNothing);
    expect(find.text('いいのですか'), findsNothing);
  });

  testWidgets('竖排行逐字拆格，整词的 Text 不再出现', (tester) async {
    await tester.pumpWidget(_host(_page()));
    await _reveal(tester, 0);

    // 每个字一个格。
    expect(find.text('ち'), findsOneWidget);
    expect(find.text('ょ'), findsOneWidget);
    expect(find.text('と'), findsOneWidget);
    expect(find.text('待'), findsOneWidget);
    expect(find.text('た'), findsOneWidget);
    expect(find.text('ー'), findsOneWidget);
    // 第二行两个词（待ったー / ！！）逐字拆开后，！ 各占一格。
    expect(find.text('！'), findsNWidgets(2));

    // 整词横排的旧渲染不应再出现。
    expect(find.text('ちょっと'), findsNothing);
    expect(find.text('待ったー'), findsNothing);
  });

  testWidgets('列序保持 vertical-rl：第一行在最右、列内自上而下', (tester) async {
    await tester.pumpWidget(_host(_page()));
    await _reveal(tester, 0);

    final chi = tester.getRect(find.text('ち'));
    final to = tester.getRect(find.text('と'));
    final ma = tester.getRect(find.text('待'));

    // 第一行（ちょっと）在第二行（待ったー！！）右侧。
    expect(chi.left, greaterThan(ma.left));
    // 同一列内，ち 在 と 上方。
    expect(chi.top, lessThan(to.top));
  });

  testWidgets('点竖排的任何一个字，回调仍带整词', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      _host(_page(), onTap: (item) => tapped.add(item.text)),
    );
    await _reveal(tester, 0);

    await tester.tap(find.text('待'));
    await tester.pump();
    expect(tapped, ['待ったー']);
  });

  testWidgets('横排块不受影响，仍按整词渲染', (tester) async {
    await tester.pumpWidget(_host(_page(), revealAll: true));

    expect(find.text('いいのですか'), findsOneWidget);
    // 横排的整词不被拆成单字。
    expect(find.text('い'), findsNothing);
  });

  testWidgets('点画面空白处收起；换点另一个框时只显示新的框', (tester) async {
    await tester.pumpWidget(_host(_page()));
    await _reveal(tester, 0);
    expect(find.text('ち'), findsOneWidget);

    // 点另一个框：只显示新的。
    await _reveal(tester, 1);
    expect(find.text('いいのですか'), findsOneWidget);
    expect(find.text('ち'), findsNothing);

    // 点画面空白处（两个框之外）：收起。
    await tester.tapAt(const Offset(350, 500));
    await tester.pump();
    expect(find.text('いいのですか'), findsNothing);
  });

  testWidgets('点按分区翻页：右 1/3 下一页、左 1/3 上一页、中间不翻', (tester) async {
    final turns = <bool>[];
    await tester.pumpWidget(
      _host(_page(), onTurnPage: (forward) => turns.add(forward)),
    );

    // 右 1/3（页面下方，避开文字框）。
    await tester.tapAt(const Offset(350, 500));
    await tester.pump();
    // 左 1/3。
    await tester.tapAt(const Offset(50, 500));
    await tester.pump();
    // 中 1/3：不翻页。
    await tester.tapAt(const Offset(200, 500));
    await tester.pump();
    expect(turns, [true, false]);
  });

  testWidgets('框被钉住时，第一下点击只收起、不翻页', (tester) async {
    final turns = <bool>[];
    await tester.pumpWidget(
      _host(_page(), onTurnPage: (forward) => turns.add(forward)),
    );
    await _reveal(tester, 0);
    expect(find.text('ち'), findsOneWidget);

    // 右 1/3 的位置上有钉住的框外的空白：先收起，不翻页。
    await tester.tapAt(const Offset(350, 500));
    await tester.pump();
    expect(find.text('ち'), findsNothing);
    expect(turns, isEmpty);

    // 再点同一位置（已无钉住框）：翻页。
    await tester.tapAt(const Offset(350, 500));
    await tester.pump();
    expect(turns, [true]);
  });

  testWidgets('横向快滑翻页：左滑下一页、右滑上一页', (tester) async {
    final turns = <bool>[];
    await tester.pumpWidget(
      _host(_page(), onTurnPage: (forward) => turns.add(forward)),
    );

    await tester.flingFrom(const Offset(300, 400), const Offset(-250, 0), 800);
    await tester.pump();
    await tester.flingFrom(const Offset(100, 400), const Offset(250, 0), 800);
    await tester.pump();
    expect(turns, [true, false]);
  });

  testWidgets('双指捏合可缩放页面（pinch to zoom）', (tester) async {
    await tester.pumpWidget(_host(_page(), revealAll: true));

    final before = tester.getRect(find.text('ち'));
    final g1 = await tester.startGesture(const Offset(120, 350));
    final g2 = await tester.startGesture(const Offset(280, 350));
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    final after = tester.getRect(find.text('ち'));
    expect(after.width, greaterThan(before.width * 1.3));
  });

  testWidgets('1x 下纵向拖动平移长页；平移后点按分区仍翻页', (tester) async {
    final turns = <bool>[];
    await tester.pumpWidget(
      _host(
        _page(),
        revealAll: true,
        height: 400, // 视口比页面矮，才有可平移的余量（真机页面远高于视口）。
        onTurnPage: (forward) => turns.add(forward),
      ),
    );

    // 纵向拖动：内容跟手移动（InteractiveViewer 平移，不再是 ScrollView）。
    final before = tester.getRect(find.text('ち'));
    await tester.dragFrom(const Offset(200, 300), const Offset(0, -120));
    await tester.pump();
    final after = tester.getRect(find.text('ち'));
    expect(after.top, lessThan(before.top));

    // 仍在 1x：点按分区照常翻页。
    await tester.tapAt(const Offset(350, 300));
    await tester.pump();
    expect(turns, [true]);
  });
}
