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
//      第一下点击只收起；横向快滑翻页；放大状态下平移到横向边界后
//      再快滑才翻页（边界内快滑仍是平移）；
//   7. 适应全屏（fitToScreen）：整页缩放进视口、水平居中留白，1x 不裁边；
//   8. 双击同一个词（竖排可跨字格）折进 onDoubleTap 快速变状态；三击开关
//      打开时第三下折进 onTripleTap，间隔超过窗口仍是两次单击；
//   9. 词卡开着时，点画面空白处或另一个框都要把词卡关掉（翻页关卡在
//      reader_screen 的 _turnPage，这里测不到）。
//
// 运行：flutter test test/manga_vertical_render_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/features/reader/models/manga_page.dart';
import 'package:song_mobile/features/reader/models/term_tooltip.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/widgets/manga_page_view.dart';
import 'package:song_mobile/features/reader/widgets/term_tooltip.dart';

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
  void Function(TextItem)? onDoubleTap,
  void Function(TextItem)? onTripleTap,
  bool enableTripleTap = false,
  int doubleTapTimeout = 300,
  void Function(bool forward)? onTurnPage,
  bool revealAll = false,
  bool fitToScreen = false,
  double height = 700,
  void Function(BuildContext)? onContext,
}) {
  final view = MangaPageView(
    manga: page,
    imageUrl: 'https://example.test/001.jpg',
    revealAll: revealAll,
    fitToScreen: fitToScreen,
    onTurnPage: onTurnPage,
    onTap: onTap == null ? null : (item, _) => onTap(item),
    onDoubleTap: onDoubleTap,
    onTripleTap: onTripleTap,
    enableTripleTap: enableTripleTap,
    doubleTapTimeout: doubleTapTimeout,
  );
  if (onContext == null) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: height, child: view),
      ),
    );
  }
  // 让测试拿到 Overlay 所在的 BuildContext（弹词卡用）。
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: height,
        child: Builder(
          builder: (context) {
            onContext(context);
            return view;
          },
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

  testWidgets('双击同一个词触发 onDoubleTap（快速变状态），单击照旧', (tester) async {
    final tapped = <String>[];
    final doubled = <String>[];
    await tester.pumpWidget(
      _host(
        _page(),
        onTap: (item) => tapped.add(item.text),
        onDoubleTap: (item) => doubled.add(item.text),
      ),
    );
    await _reveal(tester, 0);

    // 双击：第一下立刻回调 onTap，第二下折进 onDoubleTap。
    await tester.tap(find.text('待'));
    await tester.pump();
    await tester.tap(find.text('待'));
    await tester.pump();
    expect(doubled, ['待ったー']);
    expect(tapped, ['待ったー']);

    // 间隔超过窗口的两下是两次单击，不算双击。
    await tester.tap(find.text('待'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('待'));
    await tester.pump();
    expect(doubled, ['待ったー']);
    expect(tapped, ['待ったー', '待ったー', '待ったー']);
  });

  testWidgets('竖排双击跨同一词的两个字格，仍算双击整词', (tester) async {
    final doubled = <String>[];
    await tester.pumpWidget(
      _host(_page(), onDoubleTap: (item) => doubled.add(item.text)),
    );
    await _reveal(tester, 0);

    // 「待ったー」拆成三个字格，点不同的格、同一个 TextItem。
    await tester.tap(find.text('待'));
    await tester.pump();
    await tester.tap(find.text('た'));
    await tester.pump();
    expect(doubled, ['待ったー']);
  });

  testWidgets('enableTripleTap：第二下等一个窗口，第三下折进 onTripleTap', (tester) async {
    final doubled = <String>[];
    final tripled = <String>[];
    await tester.pumpWidget(
      _host(
        _page(),
        onDoubleTap: (item) => doubled.add(item.text),
        onTripleTap: (item) => tripled.add(item.text),
        enableTripleTap: true,
      ),
    );
    await _reveal(tester, 0);

    // 两下之后不立刻变状态：三击开关打开时多等一个窗口。
    await tester.tap(find.text('待'));
    await tester.pump();
    await tester.tap(find.text('待'));
    await tester.pump();
    expect(doubled, isEmpty);

    // 没有第三下：窗口过后补发双击。
    await tester.pump(const Duration(milliseconds: 400));
    expect(doubled, ['待ったー']);
    expect(tripled, isEmpty);

    // 三下：第三下折进 onTripleTap，双击不再补发。
    await tester.tap(find.text('待'));
    await tester.pump();
    await tester.tap(find.text('待'));
    await tester.pump();
    await tester.tap(find.text('待'));
    await tester.pump();
    expect(tripled, ['待ったー']);
    expect(doubled, ['待ったー']);
  });

  testWidgets('横排块不受影响，仍按整词渲染', (tester) async {
    await tester.pumpWidget(_host(_page(), revealAll: true));

    expect(find.text('いいのですか'), findsOneWidget);
    // 横排的整词不被拆成单字。
    expect(find.text('い'), findsNothing);
  });

  testWidgets('揭示框里的裸词用纸面墨色，不跟随深色主题的浅色文字', (tester) async {
    // 底板永远是不透明白（mokuro 纸面），主题（测试里回落到深色 preset）
    // 给 status-text 新词配的浅紫在白底上等于隐身——曾收到「选中的气泡
    // 看不清字」。裸词（status0、98/99、无 wordId）必须固定深墨色。
    await tester.pumpWidget(_host(_page(), revealAll: true));

    final bare = tester.widget<Text>(find.text('ち')).style?.color;
    expect(bare, const Color(0xFF1C1B1F));
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

  testWidgets('词卡开着时点画面空白处 / 点另一个框，词卡都要关掉', (tester) async {
    // 词卡是根 Overlay 上的浮层，mokuro 画面里"其他区域"占了大半屏：
    // 不关的话它会一直浮在画面（乃至翻页后的新页）上，直到 10 秒自动消失。
    // 词卡内容是 riverpod Consumer：套 ProviderScope + mock prefs（同
    // term_card_fold_layout_test）。show() 会往 Overlay 插 entry，等首帧后再弹。
    SharedPreferences.setMockInitialValues({});
    late final BuildContext hostContext;
    await tester.pumpWidget(
      ProviderScope(child: _host(_page(), onContext: (c) => hostContext = c)),
    );
    TermTooltipClass.show(
      hostContext,
      TermTooltip(term: '言う', status: '1'),
      const Rect.fromLTWH(100, 100, 50, 30),
      onSentenceTranslation: () {}, // 不传回调时 Sentence 按钮不渲染
    );
    await tester.pump(); // 测量 entry + postFrame 换定位 entry
    await tester.pump(); // 定位 entry
    await tester.pump(const Duration(milliseconds: 150)); // 弹出动画收尾
    expect(find.text('Sentence'), findsOneWidget);

    // 点画面空白处：词卡消失。
    await tester.tapAt(const Offset(350, 500));
    await tester.pump();
    expect(find.text('Sentence'), findsNothing);

    // 再点一个隐藏的文字框（揭示它）：词卡同样不出现/不残留。
    TermTooltipClass.show(
      hostContext,
      TermTooltip(term: '言う', status: '1'),
      const Rect.fromLTWH(100, 100, 50, 30),
      onSentenceTranslation: () {},
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Sentence'), findsOneWidget);
    await _reveal(tester, 1);
    expect(find.text('Sentence'), findsNothing);

    // 词卡的 10 秒自动关闭 Timer 会让 flutter_test 的 pending-timer 检查报错，
    // 测试体内先关掉（同 term_card_fold_layout_test 的做法）。
    TermTooltipClass.close();
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

  testWidgets('适应全屏：整页缩放进视口、水平居中留白，不再裁边', (tester) async {
    // 视口 400x300，页 1080x1530：适应宽度会裁掉下半页（页高 566），
    // 适应全屏则按高度缩放（页 212x300），两侧留白 (400-212)/2 = 94。
    await tester.pumpWidget(
      _host(_page(), revealAll: true, fitToScreen: true, height: 300),
    );
    final chi = tester.getRect(find.text('ち'));
    // 字号随页宽缩放（10cqw ≈ 21），框移进留白右侧的页内。
    expect(chi.width, lessThan(30));
    expect(chi.left, greaterThan(130));
    // 整页可见：页面内容不再伸出视口。
    expect(chi.top, greaterThanOrEqualTo(0));
    final pageBottom = tester.getRect(find.text('いいのですか')).bottom;
    expect(pageBottom, lessThanOrEqualTo(300));

    // 对照：适应宽度时字更大、贴着左缘。
    await tester.pumpWidget(
      _host(_page(), revealAll: true, height: 300),
    );
    await tester.pump();
    final chiWidth = tester.getRect(find.text('ち'));
    expect(chiWidth.left, lessThan(130));
    expect(chiWidth.width, greaterThan(30));
  });

  testWidgets('放大状态下：平移到横向边界后再快滑才翻页', (tester) async {
    final turns = <bool>[];
    await tester.pumpWidget(
      _host(_page(), revealAll: true, height: 400,
          onTurnPage: (forward) => turns.add(forward)),
    );

    // 双指捏合放大（同 pinch 测试：焦距居中，平移停在页中间）。
    final g1 = await tester.startGesture(const Offset(120, 200));
    final g2 = await tester.startGesture(const Offset(280, 200));
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    await g1.moveBy(const Offset(-60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pump();

    // 不在边界：左滑只是平移，不翻页。
    await tester.flingFrom(const Offset(300, 200), const Offset(-250, 0), 800);
    await tester.pump();
    expect(turns, isEmpty);

    // 一路平移到最右侧边界。每步都低于 70px 快滑阈值，只平移不翻页
    // （大幅拖动按下时若已在边界，会被当成边界快滑翻页——那是真机上的
    // 正确行为，但不是这一步想要的）。
    for (var i = 0; i < 14; i++) {
      await tester.dragFrom(const Offset(350, 200), const Offset(-60, 0));
      await tester.pump();
    }

    // 已在右边界：再左滑 → 下一页。
    await tester.flingFrom(const Offset(300, 200), const Offset(-250, 0), 800);
    await tester.pump();
    expect(turns, [true]);

    // 平移回最左边界：右滑 → 上一页。
    for (var i = 0; i < 14; i++) {
      await tester.dragFrom(const Offset(50, 200), const Offset(60, 0));
      await tester.pump();
    }
    await tester.flingFrom(const Offset(100, 200), const Offset(250, 0), 800);
    await tester.pump();
    expect(turns, [true, false]);
  });
}
