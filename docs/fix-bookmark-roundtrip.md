# MP3 书签：存得进、读得回、不再被抹掉

2026-09-27。承接 `fix-resume-position.md`（同一批工作里"位置"那一半），
这篇是"书签"那一半。

**一句话**：书签不是"显示不出来"，是**被删掉了**。旧版每 2 秒把一份
`const []` 上报一次，服务端无条件覆盖，于是全库书签清零。

---

## 1. 缺陷：一条链上的三个环节，每个都在丢数据

实测现场（Leaf 5C，`/opt/lute/lute_data/users/chengxi/lute.db`）：

```
书 274  BkAudioBookmarks = 86.989
打开书，等一次自动保存（2 秒）
书 274  BkAudioBookmarks = ''        ← 没了
清点全库：还剩书签的书 = 0 本
```

三个环节：

| # | 环节 | 旧行为 | 后果 |
|---|---|---|---|
| 1 | **读** | `_extractAudioBookmarks` 只查 `input#book_audio_bookmarks`（旧音频播放器渲染的隐藏域，早已不存在），从不读 `LUTE_YT_DATA.bookmarks` | 书签永远读不到 |
| 2 | **区分"没有"与"不知道"** | 返回 `List<double>`，默认 `const []` | 把"页面没告诉我们"折叠成"这本书没有书签" |
| 3 | **写** | `_savePosition` 每 2 秒上报这份 `[]`；服务端 `book.audio_bookmarks = data.get("bookmarks")` 无条件赋值 | 空列表进去，NULL 出来，永不停止 |

第 2 条是关键：`[]` 是**关于这本书**的事实，`null` 是**关于这个页面**的事实。
两者混为一谈，等于 app 每次开书都替服务端断言"这本书没有书签"。

---

## 2. 服务端改动

`/opt/lute/lute/read/routes.py`（备份 `.bak_20260927_resumefix`）：

```python
# reader 路由上下文：把库里的书签交给模板
video_bookmarks=book.audio_bookmarks or "",
```

```python
# save_player_data / save_youtube_player_data：只在请求确实带了键时才写
if "bookmarks" in data:
    book.audio_bookmarks = data.get("bookmarks")
```

`/opt/lute/lute/templates/read/youtube_player.html`：

```javascript
window.LUTE_YT_DATA.bookmarks = {{ video_bookmarks | tojson }};
```

`tojson` 保证它永远是一个**带引号的 JS 字符串**，没书签时是 `""`，
而**老服务端整行都不渲染** —— 这两种情况在客户端必须区分开（见下）。

---

## 3. 客户端改动

### 读（`lib/core/network/html_parser.dart`）

`_extractAudioBookmarks` 返回类型 `List<double>` → **`List<double>?`**，
两个来源按顺序尝试（与 `_extractAudioCurrentPos` 同一套路）：

1. `input#book_audio_bookmarks` —— 旧播放器的隐藏域。**空值也是权威**：
   服务端明说了"没有"，不该继续往下找。
2. `LUTE_YT_DATA.bookmarks` —— 当前服务端渲染的那个。

`_findPlayerBookmarks` 用正则取**带引号的字面量**，刻意不复用
`_readJsonString`：后者把 `""` 和"整行缺失"都折成 `null`，而这个区别
正是防清库的那一条。

### 区分（`lib/features/reader/models/page_data.dart`）

`audioBookmarks` 改为 `List<double>?`，默认值从 `const []` 改成无默认。

### 写（`lib/features/reader/utils/player_save_policy.dart` + `audio_player_provider.dart`）

```dart
List<double>? bookmarksToPost({
  required bool userEdited,
  required bool authoritative,
  required List<double> bookmarks,
}) {
  if (!userEdited || !authoritative) return null;   // null = 不带这个键
  return bookmarks;
}
```

两个条件各挡一类丢失：

- `authoritative` —— 列表确实是从页面加载到的。没读到就不写，
  不拿一个我们没见过的列表去覆盖。
- `userEdited` —— 只有用户**刚改完书签**才带书签。这是第二条破坏路径的解药：

  > 阅读页整页有 **14 天 TTL** 的 Hive 缓存（`PageCacheService._ttl`），
  > `LUTE_YT_DATA.bookmarks` 是页面的一部分，app 手里的列表可能已经是
  > 十几天前的快照。自动保存若也带书签，用户昨天在 web 端新加的书签
  > 就会被这份旧快照覆盖 —— 与"每次开书清空"同一类破坏，方向相反。
  >
  > 进度是持续变化的遥测，必须定时写；书签是用户编辑的数据，
  > 只在被编辑的那一刻写。

保存路由同时改走统一播放器列（`postPlayerData` → `postUnifiedPlayerData`，
POST `/read/save_youtube_player_data`）—— 该列才是共享播放引擎的正主
（`save_youtube_player_data` 的 docstring：*the shared media engine posts
here for every backend it drives, audio included*）。

---

## 4. 真机验收

包：`_lute_bmfresh_20260927-0227.apk`，sha1 `51a3f8548098b60d2dc8af93d0eba5bee7d8f93c`。

### 4.1 不再被抹掉（判别性实验）

书 273「JIGSAW - IVE」，本机一周没开过（无页面缓存，读到的一定是新值）：

| 步骤 | 操作 | `BkAudioBookmarks` |
|---|---|---|
| 1 | 种入 `200`，打开书 | app 读到 `[200]` |
| 2 | 服务端**在 app 加载之后**改成 `99` | `99` |
| 3 | 等 12 秒（≈6 次自动保存） | **`99`** ← 没被覆盖 |

旧版这一步会被写成 `200`。第 2 步是刻意的：只有让"app 手里的值"与
"服务端现在的值"不同，才能看出自动保存到底带不带书签。

### 4.2 用户编辑照常落库

点 `Add bookmark`（语义树里 `bounds="[375,402][450,477]"`）：

```
99  →  123.0;200.0
```

即 app 的列表 `[200]` 加上当前位置 123，排序后分号连接 —— 正是
`save_youtube_player_data` 期望的形状。

### 4.3 读得回来（渲染）

- 书 273 冷开：播放条 `02:03 / 02:40`，语义树 SeekBar `77%`，
  与我种入的 `123`（/160）完全一致 → 新页面读得对。
- 书 274：库中 `BkAudioBookmarks = 250`，播放条上 250/324 = 77% 处
  出现黑色刻度（未播轨上画黑），而 26% 处的白色刻度是**页面缓存里**的
  旧值 `86.989` —— 正好把"刻度画出来了"和"读的是缓存"两件事同时拍下来了。
- 编辑后按钮从 `Add bookmark` 翻成 `Remove bookmark`（实心图标），
  123 处（=当前位置）出现白色刻度（已播轨上画白）。

截图在 `docs/evidence/2026-09-27_bookmark_roundtrip/`。

---

## 5. 回归防线

| 文件 | 钉住什么 |
|---|---|
| `test/audio_bookmarks_roundtrip_test.dart`（12 条） | 解析分号/JSON 两种载荷；`""` → `[]` 而**缺行** → `null`；旧隐藏域优先且空值权威；写侧用一个记录型 `HttpClientAdapter` 断言**请求体**：null 时整个键不存在、`[]` 时才发空串、路由是 `save_youtube_player_data` |
| `test/audio_bookmark_save_policy_test.dart`（5 条） | `bookmarksToPost` 的四种组合；空列表只在"用户删掉最后一个"时发出 |

变异检验（把修复改回旧实现，确认测试变红）：

| 变异 | 变红的测试 |
|---|---|
| 读侧 `return null` → `return const []` | `a page that never mentions bookmarks reports null`（Expected: null, Actual: []） |
| 写侧 `if (bookmarks != null)` → 无条件带上 | `null bookmarks are omitted from the body entirely`（Expected: false, Actual: true） |
| `bookmarksToPost` 去掉守卫 | 5 条里红 3 条 |

写侧的断言刻意打在**请求体**上而不是解析结果上：这个 bug 活在请求体里，
一个只看 `PageData` 的测试会在数据库烧掉的同时全绿。

---

## 6. 遗留

1. **读的时效性（未修）**：页面缓存 TTL 14 天，所以 web 端新加的书签
   可能十几天内不在 app 里出现。非破坏性（自动保存已经不带书签了），
   但"用户改完书签、在 app 里编辑"这一条路径仍会把 app 的旧列表写回去。
   彻底的解法是把播放器数据从整页缓存里摘出来，或播放前强制刷新元数据页。
   取舍是"离线优先 vs 跨设备新鲜度"，见 `fix-resume-position.md` §7。
2. ~~`BkAudioCurrentPos` 现在是死列~~ —— 已处理。app 改走统一列之后只写
   `BkVideoCurrentPos`，服务端读取的 `video or audio or 0` 里那个 `or`
   会把合法的 `0.0` 判成假值、掉回陈旧的 audio 列，已改成
   `video if video is not None else (audio or 0)`，并证明在全服现有数据上
   行为完全一致（0 行差异）。详见 `fix-resume-position.md` §6.1。
3. **全库书签已不可恢复**：这个 bug 已经把所有书的书签清空了。
   唯一记录了原值的是书 274（`86.989`），需要的话可以手动填回。
