import 'package:flutter/material.dart';

import 'eink_scope.dart';
import 'theme_extensions.dart';

/// 播放条（MP3 / TTS 两条朗读条、YouTube 条、漫画顶条）的整套配色与尺寸。
///
/// 存在的理由：墨水屏和彩色屏要的不是"同一套布局换几个色值"，而是两套表达
/// 方式。2026-09-26 Leaf 5C 真机反馈"播放器看不清"，逐条对上是：
///
/// 1. 深紫卡面（`audio.background` #6750A4）在 Kaleido 3 的半分辨率彩色层上
///    量化成 #5E5E5E 的脏灰，压在它上面的浅色元素跟着一起塌：
///    - 播放键圆底（白 14% 叠紫）≈ #747474，与卡面只差约 1.4 级灰（16 级里）
///      → "按钮"的形状没了，只剩一个白三角浮在灰块上；
///    - 未播滑轨（描边色 30% 叠紫）≈ #6C5B99，与卡面只差约 0.4 级灰
///      → 进度条只剩一个滑块，没有轨道可读。
/// 2. 半透明在 16 级灰阶里会被量化掉（辅助区底 0.08、拖动 overlay 0.12 直接
///    归零）→ 全部换**实色**。
/// 3. 细笔画被灰阶吃掉（18/22px 图标）→ 图标整体放大一档。
/// 4. 激活态（循环 / 自动暂停 / 书签）用琥珀 #FFA000 高亮，而琥珀在灰阶里
///    是 #B5B5B5（对比 3.15:1），比未激活的纯白图标（6.44:1）**更暗** ——
///    开着的那一项反而更不显眼，方向是反的 → 改成**实心圆底 + 反色图标**：
///    "有没有块"比"什么颜色"可靠，而且换成白卡面后琥珀会彻底消失。
/// 5. 进度条两端对比不足 → 已播纯黑、未播实灰、轨道加粗、滑块加大。
///
/// 彩色主题那一支刻意与改造前逐值等价（只是把原先散在各 widget 里的 alpha
/// 计算收拢到这里），所以手机上的观感不变。
class PlayerPalette {
  /// 是否处于墨水屏模式。仅用于那些"墨水屏下干脆不画"的装饰性元素。
  final bool eInk;

  /// 卡片底色。
  final Color card;

  /// 卡片描边色；[cardBorderWidth] 为 0 时不画。
  final Color cardBorder;
  final double cardBorderWidth;

  /// 卡片投影。墨水屏为 null —— 灰阶下阴影只会变脏。
  final List<BoxShadow>? cardShadow;

  /// 主图标 / 主文字色。
  final Color icon;

  /// 次要文字（时间标签、倍速数字）。
  final Color muted;

  /// 激活态颜色（彩色主题：琥珀；墨水屏：实心块上的反色）。
  final Color active;

  /// 激活态的实心底；null 表示像彩色主题那样只用颜色区分。
  final Color? activeFill;

  /// 大播放键的圆底与键面图标色。
  final Color playSurface;
  final Color playInk;
  final double playButtonSize;
  final double playIconSize;

  /// 进度条：已播 / 未播 / 滑块 / 拖动光晕。
  final Color trackActive;
  final Color trackInactive;
  final Color thumb;
  final Color overlay;
  final double trackHeight;
  final double thumbRadius;
  final double overlayRadius;

  /// 书签刻度。
  final Color bookmark;

  /// 书签刻度落在**已播段**上的颜色。
  ///
  /// 彩色模式下已播轨是浅色，[bookmark] 本身就够看，这里取同一个值。
  /// 墨水屏下必须反色：已播轨是黑的、刻度也是黑的话，播放一越过书签，
  /// 那条刻度就整条消失（2026-09-27 Leaf 5C 实测）。
  final Color bookmarkOnActive;

  /// MP3 条上"上一书签/加书签/下一书签"这一组的底色。墨水屏下透明。
  final Color groupFill;

  /// 报错条。
  final Color errorBackground;
  final Color errorInk;

  /// 图标与文字尺寸。
  final double iconSize;

  /// 主控键（MP3 的 ±10s）用的放大档。
  final double largeIconSize;

  /// 时间 / 倍速等小字。
  final double labelFontSize;

  const PlayerPalette({
    required this.eInk,
    required this.card,
    required this.cardBorder,
    required this.cardBorderWidth,
    required this.cardShadow,
    required this.icon,
    required this.muted,
    required this.active,
    required this.activeFill,
    required this.playSurface,
    required this.playInk,
    required this.playButtonSize,
    required this.playIconSize,
    required this.trackActive,
    required this.trackInactive,
    required this.thumb,
    required this.overlay,
    required this.trackHeight,
    required this.thumbRadius,
    required this.overlayRadius,
    required this.bookmark,
    required this.bookmarkOnActive,
    required this.groupFill,
    required this.errorBackground,
    required this.errorInk,
    required this.iconSize,
    required this.largeIconSize,
    required this.labelFontSize,
  });

  /// 按当前 context 解析。墨水屏那一支的所有颜色都是**不透明**的，
  /// 见 test/player_components_test.dart 里的不透明性断言。
  factory PlayerPalette.resolve(BuildContext context) {
    final colors = context.appColorScheme;

    if (context.eInk) {
      final ink = colors.text.primary;
      final surface = colors.background.surface;
      return PlayerPalette(
        eInk: true,
        card: surface,
        cardBorder: ink,
        cardBorderWidth: 2,
        cardShadow: null,
        icon: ink,
        muted: ink,
        // 反色：黑圆底上写白图标。
        active: surface,
        activeFill: ink,
        playSurface: ink,
        playInk: surface,
        playButtonSize: 54,
        playIconSize: 32,
        trackActive: ink,
        trackInactive: colors.border.outline,
        thumb: ink,
        // 拖动光晕在灰阶下要么是一圈脏灰要么是白圈，两种都不要。
        overlay: surface,
        trackHeight: 6,
        thumbRadius: 9,
        overlayRadius: 16,
        bookmark: ink,
        bookmarkOnActive: surface,
        groupFill: Colors.transparent,
        errorBackground: surface,
        errorInk: ink,
        iconSize: 24,
        largeIconSize: 28,
        labelFontSize: 13,
      );
    }

    final icon = colors.audio.icon;
    final bookmark = colors.audio.bookmark;
    final outline = colors.border.outline;
    return PlayerPalette(
      eInk: false,
      card: colors.audio.background,
      cardBorder: outline,
      cardBorderWidth: 0,
      cardShadow: [
        BoxShadow(
          color: outline.withValues(alpha: 0.25),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
      icon: icon,
      muted: icon.withValues(alpha: 0.85),
      active: bookmark,
      activeFill: null,
      playSurface: icon.withValues(alpha: 0.14),
      playInk: icon,
      playButtonSize: 48,
      playIconSize: 28,
      trackActive: icon,
      trackInactive: outline.withValues(alpha: 0.3),
      thumb: icon,
      overlay: icon.withValues(alpha: 0.12),
      trackHeight: 4,
      thumbRadius: 7,
      overlayRadius: 14,
      bookmark: bookmark,
      bookmarkOnActive: bookmark,
      groupFill: outline.withValues(alpha: 0.08),
      errorBackground: colors.audio.errorBackground,
      errorInk: colors.audio.error,
      iconSize: 22,
      largeIconSize: 26,
      labelFontSize: 11,
    );
  }
}

extension PlayerPaletteContextX on BuildContext {
  /// 当前主题 + 墨水屏开关下的播放条配色。
  PlayerPalette get playerPalette => PlayerPalette.resolve(this);
}
