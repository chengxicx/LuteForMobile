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
  final IconData? icon;
  final VoidCallback? onPressed;

  /// 开/关型按钮的当前状态（循环、自动暂停、书签…）。
  final bool active;

  final String? tooltip;

  /// 为 null 时用 [PlayerPalette.iconSize] / [PlayerPalette.largeIconSize]。
  final double? iconSize;

  /// 主控键（±10s）用放大档。
  final bool large;

  /// 文字标签（如 AB 键的 "AB"/"A"）。给定时渲染加粗文字而不是 [icon]，
  /// 字号约为图标的 0.62 倍 —— 两三个字母的宽度与相邻图标视觉平衡。
  /// AB 复读这类"状态靠字母本身表达"的键，文字比 repeat 系图标可辨得多。
  final String? label;

  const PlayerIconButton({
    super.key,
    this.icon,
    required this.onPressed,
    this.active = false,
    this.tooltip,
    this.iconSize,
    this.large = false,
    this.label,
  }) : assert(
         icon != null || label != null,
         'PlayerIconButton needs an icon or a label',
       );

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;
    final fill = active ? palette.activeFill : null;
    final effectiveIconSize =
        iconSize ?? (large ? palette.largeIconSize : palette.iconSize);

    final contentColor = active ? palette.active : palette.icon;
    // Text 不读 IconTheme（Icon 才读），颜色必须显式给：active 态是黑圆底上的
    // 反色字，漏了颜色就是黑底黑字、整个按钮看起来是空心圆。
    final button = IconButton(
      icon: label != null
          ? Text(
              label!,
              style: TextStyle(
                color: contentColor,
                fontSize: effectiveIconSize * 0.62,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            )
          : Icon(icon!),
      onPressed: onPressed,
      // 墨水屏下 active 色是"实心块上的反色"，与 fill 成对由 palette 给出。
      color: active ? palette.active : palette.icon,
      iconSize: effectiveIconSize,
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

/// 倍速标签的统一格式:整数不带小数点(`1x`),非整数保留必要位数(`0.75x`)。
///
/// MP3 的离散档位与 TTS 的连续语速共用这一个格式函数 —— 两条播放条上
/// 同一个速度必须长得一模一样(MP3 原先固定一位小数,1.0 显示成 `1.0x`,
/// TTS 显示成 `1x`)。
String formatPlayerRate(double rate) {
  final text = rate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
  return '${text.isEmpty ? '1' : text}x';
}

/// 播放条辅助行的**统一布局**:倍速 → 循环 → 自动暂停 → AB/音色 → 影子跟读 →
/// 分隔线 → 切换播放器。MP3 与 TTS 两条播放条都走这里,槽位顺序全项目
/// 只有这一份。
///
/// 存在的理由:两边各自拼 Row 时,同一个功能会慢慢漂到不同位置(倍速在
/// MP3 是第 4 个、在 TTS 是第 1 个;"切回 MP3" 在 TTS 里插在跟读之前),
/// 用户切一次播放器就得重新找键。功能有无用 null 表达,顺序不能由调用方改。
///
/// 第 4 槽是"该播放器的专属功能":MP3 条是 AB 复读,TTS 条(Edge 引擎)是
/// 音色齿轮 —— 两条互相错开同一个槽位,切换播放器后其余键位完全镜像,
/// 唯一变化的就是这一个键(2026-10-10 Leaf 5C 反馈:音色放分隔线右侧会让
/// 切换键位置漂移,MP3 条上音色键又整个消失)。
///
/// [modeSwitch] 前画一道分隔线:它是"换一个音源",与上面那排播放设置
/// 不是一类。书里只有一种音源时 modeSwitch 与分隔线都不画。
///
/// FittedBox:窄屏(小屏/分屏)上整行等比缩小,不裁切也不换行。
class PlayerAuxRow extends StatelessWidget {
  /// 倍速步进器([PlayerRateStepper])。
  final Widget? rate;

  /// 循环当前句。
  final Widget? loop;

  /// 逐句自动暂停。
  final Widget? autoPause;

  /// AB 复读(只有 MP3 条有)。
  final Widget? ab;

  /// 音色选择(只有 Edge TTS 的 TTS 条有,占 MP3 条 AB 的槽位)。
  final Widget? voice;

  /// 影子跟读(无句子的页面为 null)。
  final Widget? shadowing;

  /// 切换播放器(MP3 ⇄ TTS);书里没有另一种音源时为 null。
  final Widget? modeSwitch;

  const PlayerAuxRow({
    super.key,
    this.rate,
    this.loop,
    this.autoPause,
    this.ab,
    this.voice,
    this.shadowing,
    this.modeSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?rate,
          ?loop,
          ?autoPause,
          ?ab,
          ?voice,
          ?shadowing,
          if (modeSwitch != null) ...[
            Container(
              width: 1,
              height: palette.iconSize,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: palette.muted,
            ),
            modeSwitch!,
          ],
        ],
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
