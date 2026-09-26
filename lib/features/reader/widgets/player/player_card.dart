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

  const PlayerCard({
    super.key,
    required this.child,
    this.errorMessage,
    this.onDismissError,
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
              _buildErrorBanner(context, errorMessage!),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String message) {
    final palette = context.playerPalette;
    // 墨水屏下报错底就是卡面本身(原先那层 20% 透明粉在灰阶里不存在),
    // 所以补一圈 1px 描边,让"这是一条独立提示"还看得出来。
    final needsBorder = palette.eInk;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        color: palette.errorBackground,
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
              style: TextStyle(
                color: palette.errorInk,
                fontSize: palette.labelFontSize,
              ),
            ),
          ),
          if (onDismissError != null)
            IconButton(
              icon: Icon(Icons.close, size: 18, color: palette.errorInk),
              onPressed: onDismissError,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss error',
            ),
        ],
      ),
    );
  }
}
