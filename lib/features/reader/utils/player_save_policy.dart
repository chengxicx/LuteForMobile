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

/// 装载音源时，要不要把播放条复位到服务端给的位置；要的话是哪个。
///
/// 返回 null 表示"没有可恢复的位置"（服务端没给，或给了 0），此时不该 seek，
/// 也不该动 state。
///
/// 为什么需要一个函数而不是一行 `if`：`state.position` **只**由播放器的
/// `onPositionChanged` 更新（`_handlePositionChanged`），而 seek 之后播放器
/// 不保证会推位置事件 —— 暂停态、以及刚 `setSource` 完还没准备好的时候都可能
/// 一个事件都不发。此时 `state.position` 会一直停在 `reset()` 留下的 0，
/// 而 2 秒后的自动保存就把这个 0 写回服务端：**打开一本书就把库里的位置清成 0**。
///
/// 实测（2026-09-27 Leaf 5C）：`BkVideoCurrentPos` 种入 `149.277379`，
/// 重开一次后库里变成 `0.0`，界面回到 `00:00`，而同一本书此前是正常恢复的 ——
/// 所以这条路径**间歇性**触发，只在 seek 恰好没推事件时踩到。与"书签被清空"
/// 是同一类破坏：写回一个我们其实没确认过的值。
///
/// 所以装载时先把目标位置落进 state（乐观写入），再 seek。这不会掩盖真实进度：
/// 播放器一旦真的开始推事件，`_handlePositionChanged` 会立刻用真实值覆盖。
///
/// 注意与用户拖动滑块的 [seek] 不同：那里 `0` 是**合法目标**（拖到开头），
/// 必须原样采用；这里的 `0` 只表示"没有可恢复的位置"。
Duration? resumePositionToAdopt(Duration? requested) {
  if (requested == null || requested <= Duration.zero) return null;
  return requested;
}
