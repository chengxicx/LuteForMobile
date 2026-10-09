import 'package:flutter/material.dart';

import '../../../../shared/theme/player_palette.dart';

/// 卡片式播放条外壳,MP3 与 TTS 朗读两个播放条共用。
///
/// 播放器从整宽色带改为浮在阅读区上方的圆角卡片:eInk 下没有阴影语义,
/// 改用描边保持同样的轮廓 —— 墨水屏下描边是 2px 实心黑(1px 在 16 级灰阶里
/// 会淡成浅灰),彩色主题下仍是投影。配色全部取自 [PlayerPalette]。
/// 报错条也在壳内,由调用方决定能否关闭。
class PlayerCard extends StatelessWidget {
  final Widget child;

  /// 非空时在卡片顶部显示报错条。
  final String? errorMessage;

  /// 报错条末尾关闭按钮的回调;为 null 时不显示关闭按钮。
  final VoidCallback? onDismissError;

  /// 中性提示(不是错误):例如「书的语言未解析,朗读按回退语言 en」。
  /// 语义与 [errorMessage] 不同,所以既不带 Error: 前缀,也不染成报错色 ——
  /// 它说的是一件需要知道、但并不是故障的事。
  final String? notice;

  /// 提示条末尾关闭按钮的回调;为 null 时不显示关闭按钮。
  final VoidCallback? onDismissNotice;

  const PlayerCard({
    super.key,
    required this.child,
    this.errorMessage,
    this.onDismissError,
    this.notice,
    this.onDismissNotice,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(16),
          border: palette.cardBorderWidth > 0
              ? Border.all(
                  color: palette.cardBorder,
                  width: palette.cardBorderWidth,
                )
              : null,
          boxShadow: palette.cardShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (errorMessage != null)
              _buildBanner(
                context,
                message: errorMessage!,
                background: palette.errorBackground,
                ink: palette.errorInk,
                onDismiss: onDismissError,
              ),
            if (notice != null)
              _buildBanner(
                context,
                message: notice!,
                // 中性色:既不是报错的粉底,也不是卡面本色(后者在彩色主题里
                // 会彻底看不见)。groupFill 是这套配色里现成的"次要区块底"。
                background: palette.groupFill,
                ink: palette.icon,
                onDismiss: onDismissNotice,
              ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildBanner(
    BuildContext context, {
    required String message,
    required Color background,
    required Color ink,
    required VoidCallback? onDismiss,
  }) {
    final palette = context.playerPalette;
    // 墨水屏下提示底就是卡面本身(原先那层 20% 透明粉在灰阶里不存在),
    // 所以补一圈 1px 描边,让"这是一条独立提示"还看得出来。
    final needsBorder = palette.eInk;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: needsBorder
            ? Border.all(color: palette.cardBorder, width: 1)
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: ink, fontSize: palette.labelFontSize),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, size: 18, color: ink),
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss',
            ),
        ],
      ),
    );
  }
}
