/// 朗读/播放高亮跟随滚动的目标位置。返回 null 表示「这一句不用动页面」。
///
/// 旧实现每换一句就 `Scrollable.ensureVisible(alignment: 0.35)`：只要高亮行
/// 不在「视口内缩 10% 的矩形」里就滚，且每次都按 35% 重算 —— 页末那一句
/// 下方没有足够内容，目标 offset 超出 [maxScrollExtent] 被夹住，末句就停在
/// 视口中间、下面一大片空白（用户看到的就是「跳到中间」）。
///
/// 这里改成锚点 + 舒适区：
///
///  * 高亮行落在 [comfortTop, comfortBottom] 区间内一律不动，页面只在
///    快掉出视口时才走一步，而不是每句整体上移；
///  * 需要动时把高亮行放到 [anchor]（默认视口 35% 高度）；
///  * 目标被夹到页末、且高亮行本来就完整可见时不动 —— 内容到底了，停在
///    底部比强行居中稳。
///
/// 所有纵向数值都相对视口顶部（逻辑像素），[viewportHeight] 是可视区高度。
double? followScrollTarget({
  required double itemTop,
  required double itemBottom,
  required double viewportHeight,
  required double currentOffset,
  required double minScrollExtent,
  required double maxScrollExtent,
  double anchor = 0.35,
  double comfortTop = 0.20,
  double comfortBottom = 0.75,
}) {
  if (viewportHeight <= 0) return null;

  final top = itemTop / viewportHeight;
  final bottom = itemBottom / viewportHeight;
  if (top >= comfortTop && bottom <= comfortBottom) return null;

  final raw = currentOffset + itemTop - anchor * viewportHeight;
  final fullyVisible = itemTop >= 0 && itemBottom <= viewportHeight;
  // 页末：再往下没有内容可滚。最后几句保持原位，别把剩余的滚动余量
  // （底部内边距、页底控件）也吃掉。
  if (raw > maxScrollExtent && fullyVisible) return null;

  final target = raw < minScrollExtent
      ? minScrollExtent
      : (raw > maxScrollExtent ? maxScrollExtent : raw);
  if ((target - currentOffset).abs() < 1.0) return null;
  return target;
}
