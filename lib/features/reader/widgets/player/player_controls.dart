import 'package:flutter/material.dart';

import '../../../../shared/theme/player_palette.dart';

/// 播放条通用的小图标按钮:统一的尺寸 / 内边距 / 命中区域,
/// 消掉各播放条自己拼出来的不一致。
///
/// 激活态用 [active] 表达而不是直接传颜色:彩色主题下是琥珀色图标,墨水屏下
/// 是"实心圆底 + 反色图标"。灰阶下琥珀(#B5B5B5,3.15:1)比未激活的纯白图标
/// (6.44:1)更暗 —— 开着的那一项反而更不显眼;"有没有块"才是不依赖颜色的信号
/// (2026-09-26 Leaf 5C 反馈)。
class PlayerIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  /// 开/关型按钮的当前状态（循环、自动暂停、书签…）。
  final bool active;

  final String? tooltip;

  /// 为 null 时用 [PlayerPalette.iconSize] / [PlayerPalette.largeIconSize]。
  final double? iconSize;

  /// 主控键（±10s）用放大档。
  final bool large;

  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.tooltip,
    this.iconSize,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;
    final fill = active ? palette.activeFill : null;

    final button = IconButton(
      icon: Icon(icon),
      onPressed: onPressed,
      // 墨水屏下 active 色是"实心块上的反色"，与 fill 成对由 palette 给出。
      color: active ? palette.active : palette.icon,
      iconSize: iconSize ?? (large ? palette.largeIconSize : palette.iconSize),
      padding: const EdgeInsets.all(4),
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
    );

    if (fill == null) return button;
    return DecoratedBox(
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      child: button,
    );
  }
}

/// 主播放键:圆形底 + 大图标,是整条播放条视觉的重心。
/// eInk 下不转圈,加载中显示沙漏(静态)。
///
/// 颜色走 [PlayerPalette]:彩色主题是"同色 14% 圆底 + 同色图标"(部分主题里
/// audio.background 与 material3.primary 同为 0xFF6750A4,主色图标画在同色
/// 卡面上会隐身);墨水屏是**实心黑圆 + 白图标**,整条条上唯一的重色块 ——
/// 原来那个 14% 圆底在灰阶里与卡面只差约 1.4 级灰,等于没有形状。
class PlayerPlayButton extends StatelessWidget {
  final bool playing;
  final bool loading;
  final VoidCallback? onPressed;

  const PlayerPlayButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;

    return Container(
      width: palette.playButtonSize,
      height: palette.playButtonSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.playSurface,
      ),
      child: IconButton(
        onPressed: loading ? null : onPressed,
        padding: EdgeInsets.zero,
        icon: loading && !palette.eInk
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.playInk,
                ),
              )
            : Icon(
                loading
                    ? Icons.hourglass_empty
                    : (playing ? Icons.pause : Icons.play_arrow),
                size: palette.playIconSize,
              ),
        color: palette.playInk,
      ),
    );
  }
}

/// − 值 + 的速度步进器,点中间数字恢复默认。MP3 与 TTS 条共用,
/// 数值含义由调用方决定(MP3 是离散档位,TTS 是连续语速)。
class PlayerRateStepper extends StatelessWidget {
  final String label;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onReset;

  const PlayerRateStepper({
    super.key,
    required this.label,
    required this.onDecrease,
    required this.onIncrease,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerIconButton(
          icon: Icons.remove,
          iconSize: palette.iconSize - 4,
          onPressed: onDecrease,
          tooltip: 'Slower',
        ),
        GestureDetector(
          onTap: onReset,
          child: Container(
            constraints: const BoxConstraints(minWidth: 34),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Text(
              label,
              style: TextStyle(
                color: palette.icon,
                fontSize: palette.labelFontSize,
                fontWeight: FontWeight.w500,
                fontFeatures: const [
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ),
        ),
        PlayerIconButton(
          icon: Icons.add,
          iconSize: palette.iconSize - 4,
          onPressed: onIncrease,
          tooltip: 'Faster',
        ),
      ],
    );
  }
}
