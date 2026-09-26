/// 把进度/书签写回服务端时，这一次请求该不该带上 `bookmarks` 字段。
///
/// 返回 null 表示"不带这个键"，返回列表表示"就写这个列表"。
/// 服务端只在请求确实带了这个键时才写（`if "bookmarks" in data`），
/// 所以 null 等于"别动库里的值"。
///
/// 两个条件必须同时成立，各自挡掉一类数据丢失：
///
/// 1. [userEdited] —— 这一次写是用户**刚改完书签**触发的，不是 2 秒一次的
///    自动保存。阅读页整页有 14 天 TTL 的 Hive 缓存（`PageCacheService`），
///    `LUTE_YT_DATA.bookmarks` 是页面的一部分，app 手里的列表可能已经是
///    十几天前的快照。自动保存若也把书签带上，用户昨天在 web 端新加的书签
///    就会被这份旧快照覆盖 —— 和"每次开书把书签清空"是同一类破坏，
///    只是方向相反。进度是持续变化的遥测，必须定时写；书签是用户编辑的
///    数据，只在被编辑的那一刻写。
///
/// 2. [authoritative] —— 书签列表确实是从页面**加载**到的（而不是从没读到、
///    拿 `const []` 兜底的默认值）。没读到就是"页面没告诉我们"，
///    此时写回任何值都是在替服务端做它没授权我们做的决定。
///
/// 反例（2026-09-27 Leaf 5C 实测）：库中 `BkAudioBookmarks` 为 `86.989`，
/// 打开书后 2 秒内被自动保存写成 NULL；清点全库，**没有任何一本书还剩书签**。
List<double>? bookmarksToPost({
  required bool userEdited,
  required bool authoritative,
  required List<double> bookmarks,
}) {
  if (!userEdited || !authoritative) return null;
  return bookmarks;
}
