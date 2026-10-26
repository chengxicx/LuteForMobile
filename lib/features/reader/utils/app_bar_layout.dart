/// 阅读屏顶栏动作区的布局常量。
///
/// 这里的规则只为一件事存在：**加载一本书的过程中，顶栏那排按钮不能挪位置**。
/// 页码导航和播放条开关都是「首屏到达后才有」的东西，它们一出现就会把左边
/// 那排图标整体往左挤，看起来像按错了地方。
library;

/// 页码导航要预留的页数。
///
/// 页面数据没到时，[pageCount] 可能是 0（`pageData` 还是 null），也可能只是
/// 只有一页的占位；这两种情况下导航都不该显示，但它**该占的位置**必须按
/// 这本书真实的页数算，否则首屏一到，导航冒出来，左边图标连同标题一起跳。
///
/// 两个来源取较大值：[bookPageCount] 来自书架列表（打开书时就有），
/// [pageCount] 来自页面数据（首屏后才有）。
int appBarReservedPageCount({
  required int pageCount,
  required int bookPageCount,
}) => pageCount > bookPageCount ? pageCount : bookPageCount;

/// 这份页面数据是不是当前这本书的。
///
/// 换书加载时 `pageData` 往往还留着上一本书的内容 —— 标题、页数、连有没有
/// 音频都是别人的。拿它决定顶栏槽位，新书比旧书"小"的时候箭头会往里缩，
/// 又是一次位置变化。所以只有 [pageBookId] 和 [bookId] 对得上才采信。
///
/// [bookId] 为 null（拿不到书架数据，只能靠页面数据）时，有页面数据就用。
bool pageDataBelongsToBook({int? pageBookId, int? bookId}) {
  if (pageBookId == null) return false;
  return bookId == null || pageBookId == bookId;
}
