import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/widgets/player/player_card.dart';
import 'package:song_mobile/features/reader/widgets/player/player_controls.dart';
import 'package:song_mobile/features/reader/widgets/player/player_timeline.dart';
import 'package:song_mobile/shared/theme/eink_scope.dart';
import 'package:song_mobile/shared/theme/player_palette.dart';
import 'package:song_mobile/shared/theme/theme_extensions.dart';

// 组件级冒烟测试:裸 MaterialApp 即可,主题缺省时 context.m3Primary /
// context.audioPlayerIcon 会落到 darkThemePreset 兜底。
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

/// 墨水屏模式下的宿主:EInkScope 决定 context.eInk。
Widget _eInkHost(Widget child) => MaterialApp(
      home: EInkScope(
        enabled: true,
        child: Scaffold(body: Center(child: child)),
      ),
    );

/// 借一次 build 把 palette / 取色结果抓出来。
Future<void> _capture(
  WidgetTester tester, {
  required bool eInk,
  required void Function(BuildContext context) read,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EInkScope(
        enabled: eInk,
        child: Builder(
          builder: (context) {
            read(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('PlayerPlayButton renders the play icon', (tester) async {
    await tester.pumpWidget(
      _host(PlayerPlayButton(playing: false, onPressed: () {})),
    );
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('PlayerPlayButton renders pause when playing', (tester) async {
    await tester.pumpWidget(
      _host(PlayerPlayButton(playing: true, onPressed: () {})),
    );
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('PlayerTimeline shows both time labels', (tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 400,
          child: PlayerTimeline(
            position: const Duration(seconds: 10),
            total: const Duration(minutes: 5, seconds: 24),
            onSeekEnd: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('00:10'), findsOneWidget);
    expect(find.text('05:24'), findsOneWidget);
  });

  testWidgets('PlayerCard renders child and error banner', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerCard(
          errorMessage: 'Error: boom',
          onDismissError: () {},
          child: const Text('BODY'),
        ),
      ),
    );
    expect(find.text('BODY'), findsOneWidget);
    expect(find.text('Error: boom'), findsOneWidget);
  });

  testWidgets('PlayerRateStepper renders its label', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerRateStepper(
          label: '1.0x',
          onDecrease: () {},
          onIncrease: () {},
          onReset: () {},
        ),
      ),
    );
    expect(find.text('1.0x'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // 墨水屏（Leaf 5C / Kaleido 3）:播放条"看不清"的回归防线。
  // 见 lib/shared/theme/player_palette.dart 顶部对 5 条成因的说明。
  // ---------------------------------------------------------------------------

  testWidgets('eInk 播放条配色不含任何半透明色', (tester) async {
    PlayerPalette? palette;
    await _capture(tester, eInk: true, read: (c) => palette = c.playerPalette);
    final p = palette!;

    // 16 级灰阶下，半透明会被量化到"整档消失"（原播放键圆底 14%、
    // 辅助区底 8%、滑轨 30%、时间标签 85%、拖动光晕 12% 都是这么丢的）。
    final mustBeOpaque = <String, Color>{
      'card': p.card,
      'cardBorder': p.cardBorder,
      'icon': p.icon,
      'muted': p.muted,
      'active': p.active,
      'activeFill': p.activeFill!,
      'playSurface': p.playSurface,
      'playInk': p.playInk,
      'trackActive': p.trackActive,
      'trackInactive': p.trackInactive,
      'thumb': p.thumb,
      'overlay': p.overlay,
      'bookmark': p.bookmark,
      'bookmarkOnActive': p.bookmarkOnActive,
      'errorBackground': p.errorBackground,
      'errorInk': p.errorInk,
    };
    mustBeOpaque.forEach((name, color) {
      expect(color.a, 1.0, reason: '$name 必须不透明，否则在灰阶上会消失');
    });
  });

  testWidgets('eInk 播放条靠描边定轮廓、播放键反色', (tester) async {
    PlayerPalette? palette;
    await _capture(tester, eInk: true, read: (c) => palette = c.playerPalette);
    final p = palette!;

    expect(p.cardBorderWidth, 2, reason: '1px 描边在灰阶上会淡成浅灰');
    expect(p.cardShadow, isNull, reason: '阴影在墨水屏上只会变脏');
    expect(p.playSurface, p.icon, reason: '播放键是实心黑圆');
    expect(p.playInk, p.card, reason: '键面图标反色');
    expect(p.activeFill, isNotNull, reason: '激活态用实心块表达，不靠颜色');
    expect(p.iconSize, greaterThan(22), reason: '细笔画会被灰阶吃掉，图标放大一档');
    expect(p.trackHeight, greaterThan(4));
  });

  testWidgets('彩色主题的播放条配色与改造前一致', (tester) async {
    PlayerPalette? palette;
    await _capture(tester, eInk: false, read: (c) => palette = c.playerPalette);
    final p = palette!;

    expect(p.cardBorderWidth, 0);
    expect(p.cardShadow, isNotNull);
    expect(p.activeFill, isNull, reason: '彩色主题只用颜色区分激活态');
    expect(p.playSurface, isNot(p.playInk), reason: '播放键仍是同色浅底 + 同色图标');
  });

  testWidgets('书签刻度在两种底色上都与底色异色（墨水屏靠反色）', (tester) async {
    // 刻度落在未播段用 bookmark、落在已播段用 bookmarkOnActive。
    // 两个都得跟所在底色分得开 —— 否则播放一越过书签，那条刻度就整条消失
    // （2026-09-27 Leaf 5C 实测：黑刻度压在黑的已播轨上）。
    PlayerPalette? ink;
    await _capture(tester, eInk: true, read: (c) => ink = c.playerPalette);
    expect(ink!.bookmark, isNot(ink!.trackInactive), reason: '未播段：黑刻度 vs 灰轨');
    expect(
      ink!.bookmarkOnActive,
      isNot(ink!.trackActive),
      reason: '已播段：已播轨是黑的，刻度必须反色成白',
    );

    PlayerPalette? color;
    await _capture(tester, eInk: false, read: (c) => color = c.playerPalette);
    expect(
      color!.bookmarkOnActive,
      color!.bookmark,
      reason: '彩色模式已播轨是浅色，刻度不需要换色',
    );
  });

  testWidgets('eInk 下 active 的图标按钮画出实心圆底', (tester) async {
    bool hasDisc() => tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .any((box) => (box.decoration as BoxDecoration).shape == BoxShape.circle);

    await tester.pumpWidget(
      _eInkHost(
        PlayerIconButton(icon: Icons.repeat, active: true, onPressed: () {}),
      ),
    );
    expect(hasDisc(), isTrue);

    await tester.pumpWidget(
      _eInkHost(
        PlayerIconButton(icon: Icons.repeat, onPressed: () {}),
      ),
    );
    expect(hasDisc(), isFalse, reason: '未激活的按钮不该有块');
  });

  testWidgets('彩色主题下 active 仍是纯色图标、不画块', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerIconButton(icon: Icons.repeat, active: true, onPressed: () {}),
      ),
    );
    final discs = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((box) => (box.decoration as BoxDecoration).shape == BoxShape.circle);
    expect(discs, isEmpty);
  });

  testWidgets('eInk 下 audioPlayerIcon 跟着页面文字色，不再用白图标', (tester) async {
    late Color icon;
    late Color pageText;
    await _capture(tester, eInk: true, read: (c) {
      icon = c.audioPlayerIcon;
      pageText = c.appColorScheme.text.primary;
    });
    expect(icon, pageText, reason: 'YouTube 条 / 漫画顶条直接画在页面上');
  });
}
