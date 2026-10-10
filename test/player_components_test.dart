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
  // MP3 与 TTS 两条播放条的辅助行共用 PlayerAuxRow:同一个功能必须永远在
  // 同一个槽位,不然切一次播放器就得重新找键(2026-10-10 用户反馈)。
  // ---------------------------------------------------------------------------

  test('formatPlayerRate:整数不带小数点,非整数保留必要位数', () {
    expect(formatPlayerRate(1.0), '1x', reason: 'MP3 原先显示 1.0x，TTS 显示 1x');
    expect(formatPlayerRate(1.5), '1.5x');
    expect(formatPlayerRate(0.6), '0.6x');
    expect(formatPlayerRate(0.75), '0.75x');
    expect(formatPlayerRate(2.0), '2x');
  });

  testWidgets('PlayerAuxRow 按固定槽位顺序排列', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerAuxRow(
          rate: const Text('RATE'),
          loop: const Text('LOOP'),
          autoPause: const Text('AUTO'),
          ab: const Text('AB'),
          shadowing: const Text('MIC'),
          modeSwitch: const Text('SWITCH'),
        ),
      ),
    );

    double x(String label) => tester.getTopLeft(find.text(label)).dx;
    expect(x('RATE'), lessThan(x('LOOP')));
    expect(x('LOOP'), lessThan(x('AUTO')));
    expect(x('AUTO'), lessThan(x('AB')));
    expect(x('AB'), lessThan(x('MIC')));
    expect(x('MIC'), lessThan(x('SWITCH')), reason: '切换键固定在最后');
  });

  testWidgets('PlayerAuxRow 缺的槽位不占位,其余顺序不变', (tester) async {
    await tester.pumpWidget(
      _host(
        PlayerAuxRow(
          rate: const Text('RATE'),
          loop: const Text('LOOP'),
          autoPause: const Text('AUTO'),
          shadowing: const Text('MIC'),
          modeSwitch: const Text('SWITCH'),
        ),
      ),
    );

    expect(find.text('AB'), findsNothing, reason: 'TTS 条没有 AB 复读');
    double x(String label) => tester.getTopLeft(find.text(label)).dx;
    expect(x('RATE'), lessThan(x('LOOP')));
    expect(x('AUTO'), lessThan(x('MIC')));
    expect(x('MIC'), lessThan(x('SWITCH')));
  });

  testWidgets('PlayerAuxRow 的 modeSwitch 传禁用键也照样渲染', (tester) async {
    // 2026-10-11 反馈:无 MP3 书的 TTS 条结尾缺一截,和 MP3 条长得不一样。
    // 契约改为「切换键恒渲染,不可用置灰」—— 结构恒同,短一截就是回归。
    await tester.pumpWidget(
      _host(
        PlayerAuxRow(
          rate: const Text('RATE'),
          shadowing: const Text('MIC'),
          modeSwitch: PlayerIconButton(
            icon: Icons.music_note,
            onPressed: null,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });

  testWidgets('PlayerIconButton 禁用时按 palette.disabled 明显置灰', (tester) async {
    Color? disabled;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                disabled ??= context.playerPalette.disabled;
                return PlayerIconButton(icon: Icons.music_note, onPressed: null);
              },
            ),
          ),
        ),
      ),
    );

    final iconContext = tester.element(find.byIcon(Icons.music_note));
    expect(IconTheme.of(iconContext).color, disabled);
  });

  testWidgets('PlayerIconButton 可用时保持 palette.icon', (tester) async {
    Color? icon;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                icon ??= context.playerPalette.icon;
                return PlayerIconButton(icon: Icons.music_note, onPressed: () {});
              },
            ),
          ),
        ),
      ),
    );

    final iconContext = tester.element(find.byIcon(Icons.music_note));
    expect(IconTheme.of(iconContext).color, icon);
  });

  testWidgets('PlayerIconButton 禁用默认只置灰,开 slashWhenDisabled 才有斜线', (
    tester,
  ) async {
    // 2026-10-11 用户反馈:主控行即使不可按也不要斜线 —— 斜线只表示
    // "功能在此不存在"(切换到不存在的音源),边界上的前后句只是暂时到头。
    bool hasSlash() =>
        tester
            .widgetList(
              find.byWidgetPredicate(
                (w) =>
                    w is CustomPaint &&
                    w.painter.runtimeType.toString() == '_DisabledSlashPainter',
              ),
            )
            .isNotEmpty;

    await tester.pumpWidget(
      _host(PlayerIconButton(icon: Icons.music_note, onPressed: null)),
    );
    expect(hasSlash(), isFalse, reason: '主控键禁用只置灰,不画斜线');

    await tester.pumpWidget(
      _host(PlayerIconButton(icon: Icons.music_note, onPressed: () {})),
    );
    expect(hasSlash(), isFalse, reason: '可用键不能有斜线');

    await tester.pumpWidget(
      _host(
        PlayerIconButton(
          icon: Icons.music_note,
          onPressed: null,
          slashWhenDisabled: true,
        ),
      ),
    );
    expect(hasSlash(), isTrue, reason: '切换键这类"功能不存在"的禁用键画斜线');
  });

  testWidgets('disabled 色与可用图标色两套主题下都可辨', (tester) async {
    // 2026-10-11 手机实测:muted(彩色 85% 白 / eInk 同墨色)做禁用态,
    // 用户"没看出不能按"。这里守住 disabled 与 icon 的可辨性。
    // 彩色主题的 disabled 带透明度,差异要合成到卡面上才看得见,所以
    // 两个颜色都先 alphaBlend 到 card 上再比。
    double channelDistance(Color a, Color b) =>
        ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255;

    for (final eInk in [false, true]) {
      PlayerPalette? palette;
      await _capture(tester, eInk: eInk, read: (c) => palette = c.playerPalette);
      final p = palette!;

      expect(
        channelDistance(Color.alphaBlend(p.disabled, p.card),
            Color.alphaBlend(p.icon, p.card)),
        greaterThanOrEqualTo(60),
        reason: 'eInk=$eInk 禁用色必须明显暗于可用图标色',
      );
      if (eInk) {
        expect((p.disabled.a * 255).round(), 255, reason: '灰阶下半透明会整档消失');
        expect(
          channelDistance(p.disabled, p.card),
          greaterThanOrEqualTo(60),
          reason: 'eInk 禁用色也不能糊进卡面',
        );
      }
    }
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
      'disabled': p.disabled,
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
