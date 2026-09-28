# ai-story 两本书的差异 & "Loading content..." 耗时 — 现场取证

设备：Leaf5C（serial 38120d06），1264x1680 @ density 300 → 逻辑 674x896。
应用：`com.schlick7.luteformobile`（release APK，`ApiLogger.enableLogging = kDebugMode` → logcat 无日志）。

## 1. 为什么两本书顶栏按钮 / 操作不同

两本书**打开的是同一个屏**（`ReaderScreen`，路由 `'reader'`），模式不是按书存的。
差别来自书自己的**页数**（服务端下发）：

| 书 | 页数 | 顶栏 | 左右三分之一点击 |
|---|---|---|---|
| 夜の色彩 | `1/1` | 书架 / 播放 / Tt / 语法 | **无反应** |
| 横浜のアパートの惨劇 | `2/3` → `3/3` | 书架 / 播放 / Tt / 语法 **+ `‹ 2/3 ›`** | 翻页 |

代码闸门都是 `pageCount > 1`：

- `lib/features/reader/widgets/reader_screen.dart:1088` — 顶栏翻页步进器 `if (pageData != null && pageData.pageCount > 1)`
- 同文件 `:249` — `_canSwipePages()`：`if (pageData == null || pageData.pageCount <= 1) return false;`
  它同时是 `_turnPage()` 的唯一前置，所以 `pageCount == 1` 的书连"点左/右三分之一翻页"都没有。

内容层面也解释了"一个是滚屏、一个是翻页"的观感：

- 夜の色彩只有 1 页，且这一页**比一屏长**（`01_current.png` 正文一直顶到 y=1677 被裁掉）→ 只能滚。
- 横浜每页（约 7–8 句）**刚好一屏放得下**（`02_yokohama_opened.png` 正文在 y≈1070 就结束）→ 翻页才是自然手势。

`ReaderScreen` 正文本身两边都是 `SingleChildScrollView`（`text_display.dart:477`），所以两本都能滚；
只是 1 页的书没有"页"可翻。

> 另一条会产生"顶栏只剩一个 ✕、逐句翻页"的路：`SentenceReaderScreen`（路由 `'sentence-reader'`，
> `06_sentence_reader.png`）。它是**整屏替换**的另一个页面，只能从阅读设置抽屉里的
> "Open Sentence Reader" 进入，且路由不持久化（`app.dart:226 _currentRoute = 'reader'` 是硬编码初值），
> 从书架点任何一本书都会 `navigateToReader()` → `navigateToScreen('reader')` 把你踢回普通阅读屏。
> 它不是按书存的属性。

### 取证

- `01_current.png` 夜の色彩，1 页，顶栏 4 个按钮
- `02_yokohama_opened.png` 横浜 2/3，顶栏多出 `‹ 2/3 ›`
- `03_yokohama_after_right_tap.png` 点右三分之一 → 2/3 变 3/3（翻页成立）
- `07_yo_no_colors_after_right_tap.png` 同样点右三分之一 → 顶栏不变、正文不动（1 页书无法翻页）

## 2. 为什么每次开书都要等 "Loading content..."

**不是 CPU 慢，也不是没做缓存 —— 是"开书"这条路径按设计绕过了页缓存。**

页缓存是有的：`PageCacheService`，Hive box `page_cache`，TTL 14 天，上限 100MB，
key = `page_cache_<bookId>_<pageNum>`。

`ContentService.getPageContent()`（`lib/core/network/content_service.dart:81`）：

```dart
if (useCache && !forceRefresh && pageNum != null) {
  // 只读缓存，未命中立刻返回 null，不发网络请求
} else {
  // 网络模式：取 metadata + 取正文，两次 HTTP，然后写缓存
}
```

开书走的是 `navigateToReader(book.id, null, book)`（`books_screen.dart:358`），
`pageNum` 是 **null** → 落到 `else` 分支 → **每次都打两次网络**，缓存里有也照样打。
翻页走的是 `pageNum != null` → 只读缓存 → 瞬时。

### 实测（`exec-out screencap` 连拍，约 0.4s 一张）

| 动作 | 点下去 → 正文出现 |
|---|---|
| 第一次打开 夜の色彩 | ≈ 1.7–2.2s |
| **两分钟后再打开同一本书**（该页早已在缓存里） | ≈ 1.4–1.7s |

第二次仍然慢、仍然显示 "Loading content..." → 证明不是"第一次没缓存"。

网络侧：从本机 `curl https://www.metaman.dpdns.org/` 的 TTFB 是 **1.5–3.0s**，
开书要 2 次往返，量级正好对得上 —— 时间花在服务端/网络，不在设备。
设备本身是 8 核 Qualcomm LAGOON + 3.5GB RAM，渲染这点日文文本毫无压力。

### 顺带发现的渲染缺陷：墨水屏下 "Loading content..." 打印两遍

`lib/shared/widgets/loading_indicator.dart:18-28`：

```dart
if (eInk)
  Text(message ?? 'Loading...')      // 墨水屏用文案代替转圈
else
  const CircularProgressIndicator(),
if (message != null) ...[            // 这段没有排除 eInk → 文案又来一遍
  const SizedBox(height: 16),
  Text(message!),
],
```

手机上是对的（转圈 + 文案），墨水屏上变成"文案 + 文案"。
`01_current.png` 之后连拍的 loading 帧和 `sentence_reader_screen.dart:466` 都走这个组件。
修法：把第二个 `if` 改成 `if (message != null && !eInk)`。

## 复现命令

```bash
ADB=~/.workbuddy-ai/binaries/platform-tools/platform-tools/adb
$ADB -s 38120d06 shell uiautomator dump /sdcard/ui.xml && $ADB -s 38120d06 pull /sdcard/ui.xml /tmp/ui.xml
# 开书计时：连拍 + 看 PNG 体积突变（loading ≈ 55KB，正文 ≈ 193KB）
for i in $(seq -w 1 14); do $ADB -s 38120d06 exec-out screencap -p > /tmp/shot_$i.png; done
```

`adb root` 在这台机器上不可用（`adbd cannot run as root in production builds`），
release 包也不能 `run-as`，所以缓存目录无法直接查看 —— 结论来自代码路径 + 计时对比。
