import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/shared/theme/eink_scope.dart';
import 'package:song_mobile/shared/widgets/loading_indicator.dart';

// 组件级冒烟测试:裸 MaterialApp 即可,EInkScope 决定 context.eInk。
Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// 墨水屏模式下的宿主。与 player_components_test.dart 的写法保持一致。
Widget _eInkHost(Widget child) => MaterialApp(
  home: EInkScope(
    enabled: true,
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('LoadingIndicator', () {
    testWidgets('非墨水屏 + message:进度圈 + 一行文案', (tester) async {
      await tester.pumpWidget(
        _host(const LoadingIndicator(message: 'Loading content...')),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading content...'), findsOneWidget);
    });

    testWidgets('非墨水屏 + 无 message:只有进度圈', (tester) async {
      await tester.pumpWidget(_host(const LoadingIndicator()));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading...'), findsNothing);
    });

    testWidgets('墨水屏 + message:文案只出现一次(回归防线)', (tester) async {
      await tester.pumpWidget(
        _eInkHost(const LoadingIndicator(message: 'Loading content...')),
      );

      // 曾经这里会命中两个 —— 墨水屏分支用 message 顶替进度圈之后,
      // 下面的副文案又追加了一遍。
      expect(find.text('Loading content...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('墨水屏 + 无 message:退回 Loading... 且只出现一次', (tester) async {
      await tester.pumpWidget(_eInkHost(const LoadingIndicator()));

      expect(find.text('Loading...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
