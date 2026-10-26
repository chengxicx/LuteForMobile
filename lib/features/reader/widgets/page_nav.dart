import 'package:flutter/material.dart';

import '../models/page_data.dart';

/// 顶栏右侧的页码导航（`‹ 1/2 ›`）。
///
/// 宽度按**这本书最宽的页码**（`<totalPages>/<totalPages>`）预留，而不是当前
/// 页：加载一本书的时候页面数据还没到（或者只是"一页"的占位），导航此刻不该
/// 显示；但它出现、或页码位数变化的那一刻，AppBar 的 actions 会整体变宽往左
/// 延伸，把左边那排图标挤走 —— 用户看到的就是「加载时上面的按钮位置会变」。
///
/// 所以：宽度只由 [totalPages] 和 [showNumbers] 决定，页面数据没到时只留空
/// 文字、箭头禁用，位置和加载完成后完全一致。
class PageNav extends StatelessWidget {
  const PageNav({
    super.key,
    required this.pageData,
    required this.totalPages,
    required this.showNumbers,
    this.onGoToPage,
    this.onOpenSlider,
  });

  /// 当前页数据。null = 还没加载完（或这份数据不属于当前这本书）。
  final PageData? pageData;

  /// 这本书的总页数（来自书架，加载前就知道）。
  final int totalPages;

  /// 设置里的「显示页码」。关掉时中间的数字区整个不出现。
  final bool showNumbers;

  /// 翻页回调。为 null 时两个箭头都禁用。
  final ValueChanged<int>? onGoToPage;

  /// 点页码打开跳页滑块。
  final VoidCallback? onOpenSlider;

  @override
  Widget build(BuildContext context) {
    // 只有页面数据本身也说这是一本多页书，导航才响应；否则只是占位。
    final page = (pageData != null && pageData!.pageCount > 1)
        ? pageData
        : null;
    final style = Theme.of(context).textTheme.bodyMedium;

    var indicatorWidth = 0.0;
    if (showNumbers) {
      final painter = TextPainter(
        text: TextSpan(text: '$totalPages/$totalPages', style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      // +16 是数字区左右的 8dp 内边距。
      indicatorWidth = painter.width + 16;
    }

    final goTo = onGoToPage;
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: (page != null && goTo != null && page.currentPage > 1)
                ? () => goTo(page.currentPage - 1)
                : null,
            tooltip: 'Previous page',
          ),
          if (showNumbers)
            GestureDetector(
              onDoubleTap: page != null ? onOpenSlider : null,
              onLongPress: page != null ? onOpenSlider : null,
              child: SizedBox(
                width: indicatorWidth,
                child: Center(
                  child: Text(
                    page?.pageIndicator ?? '',
                    style: style,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed:
                (page != null && goTo != null && page.currentPage < page.pageCount)
                ? () => goTo(page.currentPage + 1)
                : null,
            tooltip: 'Next page',
          ),
        ],
      ),
    );
  }
}
