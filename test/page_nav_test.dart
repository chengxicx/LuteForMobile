import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';
import 'package:song_mobile/features/reader/widgets/page_nav.dart';

/// 顶栏页码导航的布局稳定性。
///
/// 这是「加载书的时候上面的按钮位置会变」的回归测试：AppBar 的 actions 靠右
/// 对齐，页码导航一旦在加载完成后才出现、或者宽度变了，左边那排图标就会整体
/// 平移。这里直接比较渲染出来的箭头矩形。
void main() {
  Widget harness(PageData? page, int totalPages) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Book'),
          actions: [
            PageNav(
              pageData: page,
              totalPages: totalPages,
              showNumbers: true,
              onGoToPage: (_) {},
              onOpenSlider: () {},
            ),
          ],
        ),
      ),
    );
  }

  PageData page({required int current, required int count}) => PageData(
    bookId: 1,
    currentPage: current,
    pageCount: count,
    paragraphs: const [],
  );

  testWidgets('加载中与加载完成后箭头位置完全一致', (tester) async {
    await tester.pumpWidget(harness(null, 341));
    final loadingLeft = tester.getRect(find.byIcon(Icons.chevron_left));
    final loadingRight = tester.getRect(find.byIcon(Icons.chevron_right));

    await tester.pumpWidget(harness(page(current: 1, count: 341), 341));
    final loadedLeft = tester.getRect(find.byIcon(Icons.chevron_left));
    final loadedRight = tester.getRect(find.byIcon(Icons.chevron_right));

    expect(loadedLeft, loadingLeft);
    expect(loadedRight, loadingRight);
    // 加载完之后页码才出现，但它落在预留好的空位里。
    expect(find.text('1/341'), findsOneWidget);
  });

  testWidgets('页码位数变化不影响箭头位置', (tester) async {
    await tester.pumpWidget(harness(page(current: 9, count: 341), 341));
    final left = tester.getRect(find.byIcon(Icons.chevron_left));

    await tester.pumpWidget(harness(page(current: 100, count: 341), 341));
    final leftLater = tester.getRect(find.byIcon(Icons.chevron_left));

    expect(leftLater, left);
  });

  testWidgets('加载中箭头禁用、页码为空', (tester) async {
    await tester.pumpWidget(harness(null, 30));
    final left = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_left),
    );
    final right = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right),
    );
    expect(left.onPressed, isNull);
    expect(right.onPressed, isNull);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('页数越多留给页码的位置越宽', (tester) async {
    await tester.pumpWidget(harness(page(current: 1, count: 5), 5));
    final narrow = tester.getRect(find.byIcon(Icons.chevron_left));

    await tester.pumpWidget(harness(page(current: 1, count: 1200), 1200));
    final wide = tester.getRect(find.byIcon(Icons.chevron_left));

    // 两位页码 -> 四位页码，左边的箭头更靠左（导航整体更宽）。
    expect(wide.left, lessThan(narrow.left));
  });
}
