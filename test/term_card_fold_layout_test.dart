import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/features/grammar/models/grammar_point.dart';
import 'package:song_mobile/features/grammar/widgets/grammar_point_card.dart';
import 'package:song_mobile/features/reader/models/term_tooltip.dart';
import 'package:song_mobile/features/reader/widgets/term_tooltip.dart';

/// 词卡两按钮布局 + 参考例句折叠默认态的契约测试（2026-10-03 反馈）。
///
/// 1. 词卡按钮行的 Center 原本会把整卡撑到 240 上限——短词时文字全挤在
///    左边、右半片空白，看起来左右不对称。IntrinsicWidth 之后卡片贴内容
///    收宽：短词 + 双按钮时整卡必须明显小于 240（旧实现恒等于 240）。
/// 2. 单句语法页空间足够，参考例句·注意点默认展开；Grammar 标签页维持折叠。
void main() {
  group('GrammarPointCard 参考例句折叠', () {
    const point = GrammarPoint(
      name: '〜たがる',
      level: 'N4',
      desc: '表示第三人称的愿望。',
      reference: GrammarReference(
        sentence: '彼は行きたがっている。',
        text: '他想去。',
      ),
    );

    testWidgets('Grammar 标签页默认折叠：例句不可见', (tester) async {
      await tester.pumpWidget(_card(point));
      expect(find.text('参考例句 · 注意点'), findsOneWidget);
      expect(find.text('彼は行きたがっている。', findRichText: true), findsNothing);
    });

    testWidgets('单句语法页 initiallyExpanded: 例句默认可见', (tester) async {
      await tester.pumpWidget(_card(point, initiallyExpanded: true));
      expect(find.text('参考例句 · 注意点'), findsOneWidget);
      expect(find.text('彼は行きたがっている。', findRichText: true), findsOneWidget);
      expect(find.text('他想去。'), findsOneWidget);
    });

    testWidgets('展开后仍可手动折叠', (tester) async {
      await tester.pumpWidget(_card(point, initiallyExpanded: true));
      await tester.tap(find.text('参考例句 · 注意点'));
      await tester.pumpAndSettle();
      expect(find.text('彼は行きたがっている。', findRichText: true), findsNothing);
    });
  });

  group('词卡宽度贴内容', () {
    testWidgets('短词 + 双按钮：卡片不再撑满 240 上限', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // Ahem 测试字体的字宽 = 字号，真实设备上按钮行更窄；缩小字号保证
      // 按钮行不触到 240 上限，从而能区分「贴内容」和「撑满」两种实现。
      tester.platformDispatcher.textScaleFactorTestValue = 0.1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      // show() 里会往 Overlay 插 entry（setState），不能在 build 期间调用 ——
      // 和真机一样等首帧后再弹。
      late final BuildContext hostContext;
      await tester.pumpWidget(_tooltipHost(
        onContext: (context) => hostContext = context,
      ));
      TermTooltipClass.show(
        hostContext,
        TermTooltip(term: '紅葉', translation: '秋天的树叶', status: '1'),
        const Rect.fromLTWH(200, 400, 60, 30),
        onSpeak: () {},
        onSentenceTranslation: () {},
        onGrammar: () {},
      );
      await tester.pump(); // 测量 entry + postFrame 换成定位 entry
      await tester.pump(); // 定位 entry
      await tester.pump(const Duration(milliseconds: 150)); // 弹出动画收尾

      final box = tester.renderObject(_tooltipFinder) as RenderBox;
      expect(find.text('Sentence'), findsOneWidget);
      expect(find.text('Grammar'), findsOneWidget);
      // 旧实现：按钮行的 Center 把卡片撑到恒等于 240；新实现贴内容收宽。
      expect(box.size.width, lessThan(239));
      expect(box.size.width, greaterThan(100));

      // 词卡有个 10 秒自动关闭 Timer；flutter_test 的 pending-timer 检查在
      // tearDown 之前跑，必须在测试体内先关掉词卡。
      TermTooltipClass.close();
    });

    testWidgets('只剩 Sentence 单按钮时同样贴内容', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.platformDispatcher.textScaleFactorTestValue = 0.1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late final BuildContext hostContext;
      await tester.pumpWidget(_tooltipHost(
        onContext: (context) => hostContext = context,
      ));
      TermTooltipClass.show(
        hostContext,
        TermTooltip(term: '紅葉', translation: '秋天的树叶', status: '1'),
        const Rect.fromLTWH(200, 400, 60, 30),
        onSpeak: () {},
        onSentenceTranslation: () {},
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final box = tester.renderObject(_tooltipFinder) as RenderBox;
      expect(find.text('Sentence'), findsOneWidget);
      expect(find.text('Grammar'), findsNothing);
      expect(box.size.width, lessThan(239));

      TermTooltipClass.close();
    });

    testWidgets('长文本卡片（240 上限）：按钮行居中，左右留白相等', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.platformDispatcher.textScaleFactorTestValue = 0.1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late final BuildContext hostContext;
      await tester.pumpWidget(_tooltipHost(
        onContext: (context) => hostContext = context,
      ));
      TermTooltipClass.show(
        hostContext,
        // ~195 字：0.1 缩放下仍远超 216，把卡片顶到 240 上限，此时按钮行
        // （~136dp）明显窄于内容区，Center 的居中才真正参与布局。
        TermTooltip(
          term: '紅葉',
          translation: '秋天的树叶，在时间、距离方面向说话者的方向靠近。，发生（异常状态）。，引起。，提起，说起，特别是……，表示强调某' * 3,
          status: '1',
        ),
        const Rect.fromLTWH(200, 400, 60, 30),
        onSpeak: () {},
        onSentenceTranslation: () {},
        onGrammar: () {},
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final cardBox = tester.renderObject(_tooltipFinder) as RenderBox;
      expect(cardBox.size.width, 240.0);
      _expectRowCentered(tester, cardBox);

      TermTooltipClass.close();
    });

    testWidgets('按钮行自然宽超过内容区：FittedBox 等比缩，仍对称', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 0.48 时两个胶囊的自然总宽 ≈ 209.5dp；再放大一档让总宽超过 216，
      // 复现 OnePlus 实机「行宽 219 > 内容区 214、min Row 溢出把右边距挤没」
      // 的场景——修复前 Grammar 距卡边只剩 ~2dp 而 Sentence 保持 13dp。
      tester.platformDispatcher.textScaleFactorTestValue = 0.56;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late final BuildContext hostContext;
      await tester.pumpWidget(_tooltipHost(
        onContext: (context) => hostContext = context,
      ));
      TermTooltipClass.show(
        hostContext,
        TermTooltip(
          term: '紅葉',
          translation: '秋天的树叶' * 30,
          status: '1',
        ),
        const Rect.fromLTWH(200, 400, 60, 30),
        onSpeak: () {},
        onSentenceTranslation: () {},
        onGrammar: () {},
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final cardBox = tester.renderObject(_tooltipFinder) as RenderBox;
      // 行自然宽超过内容区（≈216）触发 scaleDown，视觉宽度被压回 ≤216。
      final rowRect = tester.getRect(_buttonRowFinder);
      expect(rowRect.width, lessThanOrEqualTo(216.5),
          reason: 'FittedBox 应把超宽的按钮行缩回内容区宽');
      _expectRowCentered(tester, cardBox);

      TermTooltipClass.close();
    });
  });
}

Finder get _buttonRowFinder =>
    find.ancestor(of: find.text('Sentence'), matching: find.byType(Row)).last;

/// 按钮行到卡片左右边的留白必须相等（2026-10-03 反馈：一边贴边一边空）。
void _expectRowCentered(WidgetTester tester, RenderBox cardBox) {
  final rowRect = tester.getRect(_buttonRowFinder);
  final cardLeft = cardBox.localToGlobal(Offset.zero).dx;
  final leftInset = rowRect.left - cardLeft;
  final rightInset = cardLeft + cardBox.size.width - rowRect.right;
  expect(leftInset, closeTo(rightInset, 1.0),
      reason: '按钮行左右留白：left=$leftInset right=$rightInset');
}

Widget _card(GrammarPoint point, {bool initiallyExpanded = false}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          GrammarPointCard(
            point: point,
            index: 0,
            initiallyExpanded: initiallyExpanded,
          ),
        ],
      ),
    ),
  );
}

/// 词卡从 overlay 里弹出；宿主把 builder 的 context 递出来供 show() 用。
Widget _tooltipHost({
  required void Function(BuildContext) onContext,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            onContext(context);
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
}

Finder get _tooltipFinder => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_AnimatedTermTooltip',
    );
