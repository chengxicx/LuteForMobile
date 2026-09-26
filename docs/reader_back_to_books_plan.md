# 从阅读页回到书架：入口方案

> 目标设备：BOOX Leaf 5C（宽 1264×1680 物理像素 @300dpi ≈ 674dp，Kaleido 3）。
> 触发：2026-09-26 真机反馈 ——「leaf5c reader 页面没有跳回 book 页面的便捷方式」。
>
> **状态：已按 A+ 实现**（2026-09-26）。拍板结果 R1=A+ · R2=`actions` 首位 · R3=撤掉
> Grammar。实现见 §3，验收项见 §4（真机部分待复验）。

## 0. 已实现的改动

| 位置 | 改动 |
|---|---|
| `reader_screen.dart` `_buildAppBar`（fullscreen / 普通两个分支） | `actions` 首位加 `_buildBooksButton()`：`Icons.collections_bookmark` → `navigateToScreen('books')` |
| `reader_screen.dart` `_buildAppBar` 同上 | 撤掉 `Icons.spellcheck`（Grammar）按钮 —— 不是阅读动作，抽屉里本来就有 |
| `reader_screen.dart` `_startHideTimer` | `context.eInk` 时直接 `return` 并令 `_isUiVisible = true`：墨水屏下顶栏常驻 |
| `docs/reader_back_to_books_plan.md` | 本文件 |

元素净增 0（加一个书架、撤一个 Grammar）。手机端唯一的行为变化是阅读页顶栏
多一个书架按钮、少一个 Grammar 按钮，自动隐藏逻辑不变。

---

## 1. 现状：为什么 Leaf 5C 上没有入口

阅读页不是 Navigator push 出来的一屏，而是 `MainNavigation` 里 `IndexedStack`
的一个 tab（`app.dart:442` `_stackRoutes['reader'] = 0`）。所以「返回」不是
`Navigator.pop`，只能靠**主导航**切 tab。主导航有三套表达：

| 屏宽 | 主导航 | 阅读页上的表现 |
|---|---|---|
| < 600dp | 底部 `NavigationBar`（Reader/Books/Grammar/Review/Stats） | 底栏在，点 Books 一下到 |
| ≥ 600dp | 左侧常驻 `NavigationRail` | **阅读页整条 rail 退场**（`app.dart:662` `if (!isWide \|\| _isReadingRoute) return content;`） |

退场是刻意的：rail 上没有一个阅读中用得到的入口，却常驻吃掉 ~52dp 行宽
（`app.dart:546-548` 的注释）。代价是阅读页在宽屏上**一个主导航入口都不剩**。

Leaf 5C 的竖屏逻辑宽度按 BOOX 的 density 落在 600dp 以上，所以走的是宽屏分支：
底栏没有、rail 没有 → 只剩顶栏的汉堡 → 抽屉 → Books，**三次操作**（而且抽屉
是左侧滑入的全屏覆盖，墨水屏上每开一次就是一次整屏刷新）。

> **落地前先确认一件事**：Leaf 5C 的 reader 页底部到底有没有那条 5 个图标的
> 底栏？没有 → 上面的判断成立；有 → 说明设备其实走了窄屏分支，问题另有原因，
> 需要先复看。判定方法：设 `eInkMode=false` 打开 reader 看一眼底栏，或在
> reader 里临时打印 `MediaQuery.sizeOf(context).width`。

---

## 2. 候选方案

| # | 做法 | 操作数 | 代价 / 风险 |
|---|---|---|---|
| **A** | reader 顶栏加一个「书架」图标按钮（`Icons.collections_bookmark`）→ `navigateToScreen('books')` | 1（顶栏可见时） | 顶栏再挤一个元素；`fullscreenMode` 下顶栏会 2s 自动隐藏，得先点一下唤出 → 变 2 次 |
| **A+** | A ＋ eInk 下顶栏**不再自动隐藏** | **1** | 常驻 ~56dp 竖屏空间（896dp 里的 6%）。但顺带**少两次整屏刷新**：现在每次上滑唤出顶栏是 0→56dp 的整屏 reflow，2s 后消失再来一次，墨水屏上这比常驻更难受 |
| **B** | 把 reader 的 `leading` 从「汉堡」换成「返回书架」箭头，抽屉改由 `Aa` 进入（`Aa` 本来就开同一个抽屉，见 `reader_screen.dart:832`） | 1 | 零新增元素；但改变所有平台「左上角=抽屉」的肌肉记忆，且 `Aa` 的语义变成两义 |
| **C** | 宽屏下阅读页也保留一条 rail / 底栏 | 1 | 和「阅读屏不要常驻导航」的既有决定直接冲突；墨水屏上还要多一次整屏 reflow，不划算 |
| **D** | 手势 / 物理键：长按 Leaf 5C 的实体翻页键 = 回书架 | 1（长按） | 物理键已接管为翻页（`HardwareKeyNavigator`）；长按语义要靠按键诊断先确认 keycode，且长按在墨水屏上没有反馈。可作为后续增强，不做主线 |

### 推荐：**A+**

理由：
1. 左上/右上的一次点击是"跳回书架"最短的路径，且不改变现有任何肌肉记忆。
2. A+ 里"顶栏常驻"这件事在墨水屏上是**双重收益**（可达性 + 少刷新），
   不是妥协。
3. 与既有约定一致：Help / Settings 屏已经用 `BackToMainButton`
   （`app_bar_leading.dart:15`，箭头 + `navigateToScreen(lastMainRoute)`）
   表达"回到进入前的主页面"。阅读页缺的正是同一件事。

---

## 3. 实现要点（A+）

### 3.1 顶栏按钮

`reader_screen.dart` 的 `_buildAppBar`（869 行起，fullscreen 分支 877-948、
普通分支 950-1004 **两处都要改，别漏**）：

```dart
actions: [
  // 书架：阅读页在宽屏上没有任何主导航入口（rail 在阅读屏整条退场），
  // 抽屉是唯一途径且要三次操作。这里给一个一次点击的直达入口。
  IconButton(
    icon: const Icon(Icons.collections_bookmark),
    tooltip: 'Books',
    onPressed: () => ref.read(navigationProvider).navigateToScreen('books'),
  ),
  if (_playerAvailable(pageData, settings)) _buildPlayerToggleButton(...),
  ...
]
```

放在 `actions` 首位（紧邻汉堡的视觉起点一侧）还是 `leading` 里另起一格，
是这一版唯一需要挑的细节：

- **`actions` 首位**：改动最小，`leading` 保持汉堡不变。
- **`leading` 里 `[←][☰]` 两格**：位置更顺手（7" 单手持机时左上角最好够到），
  但要把 `leadingWidth` 加到 ~100dp，且和 `AppBarLeading` 的既有语义打架。

倾向：先做 `actions` 首位，真机上手感不够再挪。

### 3.2 eInk 下顶栏常驻

`reader_screen.dart:457` `_startHideTimer` / `:745-754`：

```dart
void _startHideTimer() {
  // 墨水屏下顶栏常驻：一是"回书架"要随时可点，二是显隐各是一次整屏
  // reflow（0 → 56dp），常驻反而少刷新。
  if (context.eInk) return;
  _hideUiTimer?.cancel();
  _hideUiTimer = Timer(const Duration(seconds: 2), _hideUi);
}
```

配套：`textSettings.fullscreenMode && !_isUiVisible` 那几处 margin
（788 / 809 / 1351 行）在 eInk 下自然走不到，不用改。

### 3.3 顶栏拥挤度

Leaf 5C 的 reader 顶栏现在有：`☰` · 标题 · 收起播放条 · `Aa` · 拼写检查 ·
`1/3` · `‹` · `›`。再加一个「书架」= 8 个元素。

建议同时把 **`拼写检查`（Grammar）从阅读页顶栏拿掉** —— 它不是阅读动作，
抽屉里本来就有 Grammar。腾出来的位置正好给「书架」，元素数量不变。

> 另一个方向：`showPageNumbers` 在墨水屏预设里是建议关的（P1-2），关掉后
> `1/3` 不占位，又省一格。

---

## 4. 验收

- [ ] Leaf 5C（eInk 开）：阅读页顶栏一直可见，点「书架」**一次**到书架
- [ ] 手机（eInk 关）：顶栏行为与现在完全一致（仍 2s 自动隐藏），只是多一个书架按钮
- [ ] 从书架点书进入 reader → 点书架 → 回到书架时列表滚动位置与筛选状态保留
      （`_handleNavigateToScreen('books')` 会 `loadBooks()`，确认不会重置筛选）
- [ ] 阅读页静止 10s 无自发重绘（顶栏常驻不应引入 tick）
- [ ] `sentence-reader` 不受影响（它有自己的底栏，已含 Books，见
      `sentence_reader_screen.dart:528`）

---

## 5. 拍板记录

| # | 问题 | 结论 |
|---|---|---|
| R1 | 入口形态 | **A+** —— 顶栏按钮（一次点击）+ eInk 下顶栏常驻 |
| R2 | 按钮位置 | `actions` 首位（`leading` 保持汉堡不变） |
| R3 | 是否顺手把 Grammar 从阅读页顶栏撤掉 | 撤 —— 腾出位置，阅读页不需要它 |

实现后仍未做的一件事：**顶栏常驻会占掉 56dp 竖屏空间**，在 896dp 高的屏上约 6%。
真机上如果觉得正文区变矮得不划算，退路是只保留 A（按钮照加、自动隐藏照旧），
代价是墨水屏下要先点一下唤出顶栏再点书架 —— 两次操作，但仍是原路径（三次）的改善。
