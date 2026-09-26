# 修复：MP3 播放位置存进去了，但读不回来；切后台回来进度归零

**日期**：2026-09-27
**设备**：BOOX Leaf5C（`38120d06`），Kaleido 3，1264×1680
**书**：274《小さな恋のうた - Aragaki Yui》（05:24，MP3）
**交付**：`_lute_resumefix4_20260927-0157.apk`（sha1 `a696f97c159d615ae04684f6993ca29dbbe34404`）

---

## 0. 一句话

位置往返的两半——**存**和**读**——各自都通，但读的那半去**一个已被服务端删掉的 DOM 元素**
里找数据，所以恒为 null；而且 `stop()` 会把播放器的内部位置清零，导致"回到前台按播放"
又从 0 开始。两处都修在客户端。

---

## 1. 缺陷一：读位置读的是被删掉的元素

### 1.1 服务端换了载体

这个 fork 移除了旧的 audio player（`read/index.html` 原注释：
*"the old audio-player-container player was removed"*），MP3 书改走**视频播放器的 include**，
位置随之换成了 `LUTE_YT_DATA.startPos`：

```jinja
{# lute/templates/read/index.html:119-127 #}
{% elif book_type != "manga" %}
{% if book.audio_filename %}
{% include "read/youtube_player.html" %}      {# ← MP3 书走这条 #}
{% endif %}
```

```jinja
{# lute/templates/read/youtube_player.html:10 #}
window.LUTE_YT_DATA.startPos = {{ video_current_pos }};
```

而 `video_current_pos` 是服务端**专门为兼容旧数据**折进来的：

```python
# lute/read/routes.py:696-698
# For books that previously used the removed legacy audio player
# the position was stored in audio_current_pos; fall back to it so
# the unified player resumes from the same place.
video_current_pos=book.video_current_pos or book.audio_current_pos or 0,
```

### 1.2 客户端还在读旧元素

```dart
// 改前：lib/core/network/html_parser.dart
Duration? _extractAudioCurrentPos(html.Document document) {
  final positionInput = document.querySelector(
    'input[id="book_audio_current_pos"]',   // ← 服务端已不渲染
  );
  ...
}
```

服务端源码里搜 `book_audio_current_pos` **零命中**（只有 static 目录下旧 APK 的二进制匹配）。
于是 `PageData.audioCurrentPos` 恒为 null → `loadAudio` 跳过 seek → 永远从 0 开始。

第二条路也断着：同一个 script 块里的 `startPos` 确实被解析进了 `YoutubeData`，
但 `_extractYoutubeData` 对 MP3 书**主动返回 null**（`videoId` 为 null），
而 `startPos` 也只被视频播放器消费（`reader_screen.dart:1446` → `YoutubePlayerView`）。

### 1.3 修法

`lib/core/network/html_parser.dart`：两个来源按顺序试（旧 input 优先，兼容还带旧播放器的
服务端；没有再退到 `LUTE_YT_DATA.startPos`），两份文档都搜（播放器块由哪个端点投递会变），
秒 → `Duration` 改用**毫秒**（存的那侧发 `inMilliseconds / 1000.0`，截断会让每次重开往后退），
并补了 `ApiLogger` 日志——这条路径此前**没有任何可观测性**。

**没有动** `_extractYoutubeData` 对 MP3 返回 null 的行为：读 `startPos` 不能顺带把 MP3 书
变成"YouTube 书"，那会换成 iframe 播放器。已加测试钉住。

---

## 2. 缺陷二：切后台回来，播放条归零且按播放从头开始

切后台会停播（`shouldStopAudioOnLifecycleChange` 只认 `paused`），而
`_audioPlayer.stop()` 会把位置清零并推 `position = 0` 事件回来 —— 那是 audioplayers
的正常行为，不是数据丢了。但「回前台」这条路径不会重新拉页面
（`_checkServerPage()` 只在服务端页码不同时才翻页），所以不会走 `loadAudio`，
也就没机会 seek 回去。

### 2.1 三处改动

1. **`suspendForBackground()`**（provider，新增）：切后台只停播，**保留** `_lastAudioUrl`
   与进度；不再用 `reset()`（那是"卸载音源"语义，换书/关页/切模式才该用）。
   保留 `_lastAudioUrl` 是必须的——`play()` 的重装兜底要靠它。
2. **`restoreAfterBackground()`**（provider，新增）：`resumed` 时把播放条复位到切走前的位置。
   刻意**不自动起播**：后台停播是设计，这里只负责让播放条别假装什么都没播过。
   不在 `suspendForBackground()` 里立刻写回，是因为 `stop()` 推的 `position=0` 事件是异步的，
   紧接着写回会被它盖掉。
3. **`_reloadSourceAndPlay()`**（provider，修既有缺陷）：目标位置改为在**动音源之前**取。

第 3 点是实测才发现的关键：

```dart
// 改前 —— setSource*() 已经推了 position=0 事件回来，这里读到的是 0
await _audioPlayer!.setSourceDeviceFile(audioFile.path);
final pos = state.position > Duration.zero ? state.position : const Duration(milliseconds: 1);
await _audioPlayer!.seek(pos);
```

结果"从原位置重装起播"退化成"从头播"。这条路径原本只服务于"resume 无效"的兜底
（那种情况位置本来就是 0），所以缺陷一直潜伏；现在它还要负责从后台回来后的续播，才暴露。

---

## 3. 真机验证

### 3.1 修复前的证据链

| 步骤 | 测量 | 结论 |
|---|---|---|
| 播放 10 秒 | 50.0% → 53.8% | 确实在播 |
| 按 HOME（`01:21:43`） | `mLastPausedActivity` = 我们 | 真进了 `paused` |
| 切后台期间 | 服务端 `01:21:44` 收到 `save_player_data` | `_reset()` 里那次存**发生了** |
| 回到前台（`singleTop` 复用，`ActivityRecord{2791bdd}` 哈希未变） | 进度 53.8% → **1.0%**，`00:00 / 05:24` | **归零** |
| `am force-stop` + 冷启动 | 进度 **1.0%**，`00:00 / 05:24` | **冷启动同样不恢复** |

数据库（`/opt/lute/lute_data/users/chengxi/lute.db`）：

```
BkID  title                        BkAudioCurrentPos
274   小さな恋のうた - Aragaki Yui   191.814
```

`191.814s` = 03:11.8 = 59.2%，与切后台那一刻的进度吻合 → **服务端存对了，客户端没读回来。**

**附带发现（比"不恢复"更糟）**：旧版打开书会把存的位置**冲成 0**——
auto-save 每 2 秒把 `state.position`（= 0）写回库。实测 `191.814 → 0.0`。
只是翻开看一眼就把用户的进度毁掉。

### 3.2 修复后的实测（v4 包）

| 步骤 | 测量 | 结果 |
|---|---|---|
| 冷启动 | 进度 27.6%（= 86.989s） | ✅ 恢复 |
| 播放 10 秒 | 27.6% → 30.6% | ✅ 正常 |
| 切后台 8 秒 → 回前台 | **30.8%**（修复前是 1.0%） | ✅ 位置保住 |
| 按播放 | **30.8% → 33.6%**，界面 `01:46 / 05:24`，歌词停在原处 | ✅ 接着播，不再从 0 |

### 3.3 中途踩的坑（值得记）

第一版修复只做了第 1、2 点，实测"播放条停在了 30.9%"就以为成了 —— 一按播放却掉回 3.7%。
**只量显示、不量行为，会把半截修复当成修复。** 后来靠截图时间戳与 `debugPrint` 时间对齐
（`01:52:49` 正好在第二次按播放后 1 秒）才定位到 `_reloadSourceAndPlay()` 里的读取顺序问题。

### 3.4 静态验证

- `flutter analyze`：194 issues / **0 error**（与基线持平，改动文件无新增 issue）
- `flutter test`：**19/19 文件全绿**
- **变异检验**：把 `startPos` 回退禁用 → `audio_resume_position_test.dart` **4 条红**
  （旧 input / 无块 / YouTube 守卫 3 条仍绿），证明测试有判别力

---

## 4. 回归防线

`test/audio_resume_position_test.dart`（新建，7 条）。这条契约此前**零覆盖**——
`test/` 下没有任何文件引用 `book_audio_current_pos`，所以它坏掉时没有任何东西会变红。

1. MP3 页从 `LUTE_YT_DATA.startPos` 恢复位置（**核心回归**）
2. 小数部分不丢（`12.345` → `12345ms`）
3. 旧 input 存在时仍然优先（向后兼容）
4. 播放器块落在 text 文档里也能找到
5. 完全没有播放器块时返回 null（不是伪造的 0）
6. `startPos = 0` 是"位置为 0"而非"字段缺失"
7. MP3 块不会激活视频播放器（`page.youtube == null`、`hasAudio == true`）

第 2 节的 provider 改动**没有单测**：`AudioPlayerNotifier.build()` 会 `new AudioPlayer()`，
需要平台通道，仓里没有对应假对象；而这里真正的风险在平台交互（`stop()` 的事件时序、
`seek()` 对 stopped 播放器的行为），单测也照不到。这一半以真机验证为准。

---

## 5. 遗留：需要服务端决策的两件事

### 5.1 `video_current_pos` 会永久遮住 app 存的位置（影响 17/21 本）

服务端 `startPos = video_current_pos or audio_current_pos`，**video 列优先**；
而 app 存的是 `audio_current_pos`（`POST /read/save_player_data`）。
`save_youtube_player_data` 的注释明说这是统一播放器的列：*"The shared media engine
posts here for every backend it drives, audio included"* —— 也就是说 **video 列才是当前的
正主，app 写的是遗留列**。

app 侧对 video 列是**零引用**（`grep -rn "video_current_pos\|postYoutubePlayerData" lib/`
→ 空），既不读也不写。所以只要这本书曾在**浏览器**里播过一次，`video_current_pos`
就永久非空，app 之后无论播到哪，重开都被拉回浏览器那个旧位置。

分库统计（`lute_data/users/chengxi/lute.db`）：

```
有音频文件的书                                    21
  其中 video 列非空（app 的位置被遮挡）            17   ← 81%
两列都非空且相差 >1s                              2
    BkID 55  「坏掉了」          audio   6.0   video 206.3
    BkID 285 「日が落ちるまで」   audio   0.0   video 296.5
```

只有 2 本现在明显不一致，是因为其余 15 本被"同步"了 —— app 每次打开都把 video 的值
读出来、再原样写回 audio 列（书 274 实测 `86.989304` → `86.989`）。也就是说**app 自己的
进度对这 17 本从来没有被保留过**，只是恰好与浏览器的旧值相同。

两个方向，都需要动**共享契约**，所以留给用户拍板：
- **A**：app 改post `save_youtube_player_data`（对齐统一播放器）——顺带让浏览器和 app
  共享进度；风险是改了保存契约，影响网页端。
- **B**：服务端把优先级改成 `audio_current_pos or video_current_pos`（或按 book_type 分流）
  ——风险是动生产服务端，且会影响真正在看视频的书。

### 5.2 书签不只是"读不回"，重开书会把它们**删掉**（已实测）

`book.audio_bookmarks` 全仓只有模型定义与保存语句，**没有任何回传路径**：
- 写：`read/routes.py:870`
- 读：`.py` / `.html` / `.js` 搜 `audio_bookmarks` / `BkAudioBookmarks` → 无

客户端 `_extractAudioBookmarks` 读的 `input[id="book_audio_bookmarks"]` 同样是被删掉的旧元素，
所以 `PageData.audioBookmarks` 恒为 `[]`。**但保存是照常发的**，于是每 2 秒把空列表写回库：

```dart
// 客户端：列表恒为空，却照样上报
_savePosition() → saveAudioPlayerData(bookmarks: state.bookmarkPositions /* == [] */)
```
```python
# 服务端：无条件覆盖
book.audio_bookmarks = data.get("bookmarks")
```

真机实测（书 274，Leaf5C）：

| 步骤 | `BkAudioBookmarks` | 界面 |
|---|---|---|
| 加一个书签（位置 86.989） | `86.989` | 刻度出现（已播轨上有一道白色缺口） |
| `am force-stop` + 重开 → seek 到 61% | **（空）** | 刻度**消失**，已播轨变连续 |

**结论：书签不是"重开后画不出来"，而是被真的删了。** 这是与位置同源的数据破坏，
但比位置那次更彻底 —— 位置至少还有服务端兜住（`startPos`），书签连读的通道都没有。

而且它**无法只改客户端修掉**：客户端手上没有权威列表，无论发 `[]` 还是干脆不带这个键，
服务端 `data.get("bookmarks")` 都会把列写成 `[]` / NULL。两个方向：

- **最小改动（服务端）**：只在请求**确实带了这个键**时才写
  （`if "bookmarks" in data: book.audio_bookmarks = ...`），并让客户端在"从未成功加载过"
  时**不带**该键。代价是书签在 app 里仍然看不到（刻度不会恢复），但至少不再丢数据。
- **完整改动（服务端 + 客户端）**：在播放器模板里像 `startPos` 那样回传书签
  （如 `LUTE_YT_DATA.bookmarks`），客户端解析后原样往返 —— 刻度能恢复，数据也不再丢。


---

## 6. 未处理

- 静态目录 `/opt/lute/lute/static/` 里累积 **20 个交付 APK，约 560MB**（整个 static 目录 916M）。
  按 `AGENTS.md` 约定"等用户确认后再清理"，尚未删除。
- 工作区未提交改动（本轮新增/修改见 `git status`）。
