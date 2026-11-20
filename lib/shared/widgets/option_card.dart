import 'package:flutter/material.dart';

import '../theme/eink_scope.dart';
import '../theme/theme_extensions.dart';

/// 一张「入口卡」：图标 + 标题 + 一行说明 + 可选的尾部控件。
///
/// Review 的落地页用它列出两种复习方式（原生 FSRS / 看图背单词）。刻意不用
/// [Card]：`Card` 在 LCD 上带 elevation、在墨水屏上又要靠全局主题去压阴影，
/// 而这里要的是一套「描边即边界」的形态 —— `Material(shape) + InkWell` 能让
/// 视觉边界与可点击区域完全重合。
///
/// * 墨水屏（[BuildContext.eInk]）：**方角 + 纯黑 1.2px 描边、零阴影**。全局
///   `applyEInkTheme` 已关掉 splash/highlight，这里不重复设。
/// * `onTap == null` 即禁用态：文字降到次级色、描边变淡，尾部可放 Retry。
class OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 副标题最多几行。禁用的卡要写原因，所以允许两行。
  final int subtitleMaxLines;

  const OptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.subtitleMaxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final eInk = context.eInk;
    final scheme = context.appColorScheme;
    final enabled = onTap != null;

    final textColor = enabled ? scheme.text.primary : scheme.text.secondary;
    final borderColor = eInk
        ? (enabled ? const Color(0xFF000000) : const Color(0xFF9E9E9E))
        : (enabled ? scheme.border.outline : scheme.border.outlineVariant);

    return Material(
      color: scheme.background.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: eInk ? BorderRadius.zero : BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: eInk ? 1.2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // 76 而不是 Material 的 56 最小高：两张卡并排时 56 在 674px 宽的
        // 墨水屏上挤成一条，触控也偏窄；360px 手机上仍然不溢出。
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 28, color: textColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: textColor,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.text.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  IconTheme.merge(
                    data: IconThemeData(color: textColor, size: 20),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: textColor),
                      child: trailing!,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
