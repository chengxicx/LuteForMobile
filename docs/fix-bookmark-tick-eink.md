# 墨水屏：书签刻度在「已播段」上会整条消失

**发现时间**：2026-09-27
**设备**：BOOX Leaf 5C（`38120d06`，1264×1680 / 300dpi）
**怎么发现的**：给「音量键停播」那轮做 MP3 播放条补验时，顺手验书签刻度。

---

## 两个问题

### 1. 改造前的刻度 x 公式是错的（已在本轮修好）

改造前 `audio_player.dart` 用**屏幕宽度**算刻度位置：

```dart
left: bookmarkProgress * MediaQuery.of(context).size.width - 2,
```

但 Material 的 `Slider` 滑轨左右各内缩了一个 `overlayRadius`，滑块中心在
`inset + fraction * (width - 2*inset)`。用屏幕宽度算，刻度会**系统性偏移**，
和滑块对不上（越靠两端差得越多）。

现在由 `_BookmarkTickPainter` 用与滑块同源的公式画，
`trackInset: palette.overlayRadius`。

**真机实测对齐**（加书签时滑块中心 vs 刻度中心）：

| | 位置 |
|---|---|
| 加书签时滑块中心 | x = 287.0 |
| 刻度中心 | x = 287.5 |

差 **0.5px（0.27dp）**，在抗锯齿噪声内 → 对齐正确。

另一条独立证据：点「上一书签」后滑块回到 x=285，与当初加书签的位置一致。

### 2. 刻度色与已播轨同色 → 播放越过书签后刻度消失（本轮修掉）

`PlayerPalette` 的墨水屏分支里 `bookmark: ink`（黑），而已播轨
`trackActive` 也是 `ink`（黑）——**黑刻度压在黑轨上**。

实测对照（两条书签，分别在 x≈160 与 x≈288）：

| 滑块位置 | 已播段覆盖范围 | 能找到的刻度 |
|---|---|---|
| x = 109（书签左边） | 75..126 | **两条都在**（落在灰的未播轨上） |
| x = 520（书签右边） | 75..520 | **一条都找不到**（落在黑的已播轨上） |

## 修法

`PlayerPalette` 新增 `bookmarkOnActive`：

- 彩色模式：与 `bookmark` 同值（已播轨是浅色，不需要换色）；
- 墨水屏：`surface`（白）—— 与已播轨反色。

`_BookmarkTickPainter` 新增 `activeColor` 与 `playedFraction`，
按每条刻度所在的段（`clamped <= playedFraction`）选色。

`test/player_components_test.dart` 新增一条契约测试，钉住的是**可读性**而不是实现：

```dart
expect(ink.bookmark,          isNot(ink.trackInactive));  // 未播段：黑刻度 vs 灰轨
expect(ink.bookmarkOnActive,  isNot(ink.trackActive));    // 已播段：必须反色成白
expect(color.bookmarkOnActive, color.bookmark);           // 彩色模式不换色
```

## 顺带量到的几何（供以后核对）

| 项 | 实测 |
|---|---|
| 刻度尺寸 | 3.2dp 宽 × 10.1dp 高（= 逻辑 `3 × (30 - 20)`） |
| 刻度相对轨道 | 轨道 6dp 高，刻度上下各露出约 2dp |
| 轨道（未播） | 6dp / `#79747E` |
| 轨道（已播） | 8dp / `#1C1B1F`（Flutter 的 active track 本来就比 inactive 厚，非我方设定） |
| 滑块 | 18dp 直径 |

> 注意：`CustomPainter` 的 `Size` 是**逻辑像素**。一开始按物理像素算，
> 以为刻度应该是 3×36 物理 px，量出来 6×19 就以为画错了 —— 实际 3dp×10dp
> × 1.875 = 5.6×18.75 物理 px，完全对得上。

---

## 未完成

本轮改动**已构建出包并放进 CDN 静态目录**，但**没能在真机上安装验证** ——
本机 shell 环境中途损坏（`/dev/null` 消失，所有命令 exit 127），
`adb install` / CDN 下载都没跑成。

- 产物：服务器 `/opt/lute_mobile_src/build/app/outputs/flutter-apk/app-release.apk`
- sha1：`92f791fdfa2708241f5fe7c610c4cbb3018e8dbc`（28132386 bytes）
- CDN：`https://www.metaman.dpdns.org/static/_lute_tickfix_20260927-0037.apk`

**待办**：装上后在真机上按上面的对照表复验一次 ——
把滑块拖到书签左边，两条刻度都该在；拖到右边，刻度应变成**白色**压在黑轨上。
