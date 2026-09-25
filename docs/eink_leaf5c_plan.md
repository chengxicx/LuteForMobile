# LuteForMobile 墨水屏适配方案（文石 BOOX Leaf 5C / Android 13）

> 目标设备：**BOOX Leaf 5C**（7" Kaleido 3）。代码位置基于当前工作区 `LuteForMobile/`。

## 执行状态（2026-09-25）

拍板结果：D1① 运行时开关 · D2① 4 级灰底 + 未学加粗 · D3② 左右区域点击翻页 ·
D4① 彻底停 250 ms tick · D6① 手写笔只当触摸 · TTS 走服务端（Edge）。

| 批次 | 内容 | 状态 |
|---|---|---|
| B1 | `eInkMode` 开关 + 主题去动效 + 静态 loading + 阅读页刷新面收口 | ✅ 已改；analyze 0 error，palette/playing-line 27 用例过 |
| B2 | 物理翻页键 + 按键诊断对话框 | ✅ 已改；**待真机确认 Leaf 5C 翻页键的 keycode** |
| B3 | 停 TTS / YouTube 心跳 + 一键预设 | ✅ 已改；tts_player 三个文件 15 用例过 |
| B4 | 灰阶状态表达（D2①：`einkStatusBackground` 4 档灰底 + 新词加粗，`text_display.dart` 接入）+ 预设里机内 TTS 一次性切 Edge | ✅ 已改；analyze 0 error（净减 6 条告警），40 用例过 |

落地时踩到的一个坑（已修）：**别在 Riverpod Notifier 里 `ref.read(settingsProvider)`** ——
`SettingsNotifier.build` 会读自己的 state，测试环境没有 SharedPreferences，直接
`Bad state: Tried to read the state of an uninitialized provider`，7 个 tts_player 用例全红。
改法是让 UI 层把开关当参数传进去（`play({bool tickPosition = true})`）。

---

## 1. 设备硬约束

| 项目 | 参数 | 对软件的直接含义 |
|---|---|---|
| 屏幕 | 7" E Ink Kaleido 3，黑白 **1680×1264 @300 ppi** | 竖屏逻辑区约 1264×1680，**3:4**，比常见手机短而宽 |
| 彩色层 | **840×632 @150 ppi**，4096 色 | 彩色是**半分辨率**：彩色底块/细边框必糊，**彩色不能承担精细信息** |
| 灰阶 | 16 级 | 半透明、渐变、阴影会糊成脏灰；细字重发灰消失 |
| SoC / 内存 | 高通 **SM6350** 八核 2.0 GHz / 4 GB LPDDR4X / 64 GB eMMC 5.1（TF 至 2 TB） | 性能不是瓶颈，**刷新次数**才是 |
| 系统 | **Android 13 + BOOX OS 4.1**（开放系统，第三方 App 自动适配优化参数） | 系统侧可按 App 精细配置（EinkWise），见 §6 |
| 输入 | 电容触摸 + **左侧实体翻页键** + **手写笔支持（4096 级压感，笔需选配）** | 翻页应做成物理键；笔可精确点词（零成本，见 P0-7） |
| 音频 | 扬声器 + 双麦克风 + 蓝牙 5.0 | TTS/听书可用，蓝牙更省电 |
| 电池 | **2000 mAh** | 比 Leaf 3C 的 2300 更小，**耗电优化优先级更高** |
| 其他 | 175 g，155×137×8.5 mm，Wi-Fi 5，多级双色温前光 | — |
| 分发 | 国行**无 Google Play** | APK 需侧载；系统 TTS 引擎语种可能不全（见 §5 小确认） |

### 相比 Leaf 3C 的实质差异（上一版方案的变更点）

| 项 | Leaf 3C | Leaf 5C | 方案怎么变 |
|---|---|---|---|
| 系统 | Android 11 | **Android 13 + BOOX OS 4.1** | ✅ 系统侧可按 App 配置刷新/动画过滤/全刷频率 → **P2 原生 E-Ink API 取消** |
| 手写笔 | 无 | **支持（选配）** | 🆕 新增 P0-7（结论：无需改代码） |
| 电池 | 2300 mAh | **2000 mAh** | ⚠️ 停 tick / 降轮询 / 关无用前台服务的收益更大；验收指标放宽 |
| 彩色 | 150 ppi | **840×632（半分辨率）** | 结论不变，论据更强：状态色必须让位给灰阶/字重 |
| 音频 | 扬声器 + 单麦 | 扬声器 + **双麦** | 录音场景更多，但本 app 不涉及 |
| SoC | 未指明 | SM6350 | 无影响 |

**三条原则不变**：少刷新（去掉一切连续动画）· 少灰阶（不用半透明/阴影/细渐变）· 少等待（点击后不能等网络）。

---

## 2. 现状盘点：代码里对墨水屏不友好的点（与机型无关，Leaf 5C 同样适用）

| # | 位置 | 现状 | 墨水屏影响 |
|---|---|---|---|
| A1 | `reader_screen.dart:1339-1359` | 拖动翻页用 `TweenAnimationBuilder` 跟手位移 + 松手 200 ms 回弹 | ❌ 拖动过程每帧重绘，**最严重的刷新源** |
| A2 | `reader_screen.dart:1351` | `settings.pageTurnAnimations` → `_PageTransition` | ❌ 已有开关但默认 true，eInk 需强制关 |
| A3 | `reader_screen.dart:684/701/734` | 3 处 `AnimatedContainer(200ms)`（播放条/顶栏显隐） | ❌ UI 显隐各触发 200 ms 连续刷新 |
| A4 | `text_display.dart:122-138` | 词高亮/多选用 `BoxShadow(blur:12, spread:3)` | ❌ 16 灰阶下 = 脏灰块，且扩大重绘区域 |
| A5 | `text_display.dart:598-607` | `Scrollable.ensureVisible(300ms)` | ❌ 已判断 `disableAnimations`，但系统动画开关不一定打开 |
| A6 | `tts_player_provider.dart:555` | **每 250 ms** 的 `Timer.periodic` 推送播放位置 | ❌ 朗读时**每秒 4 次全场重建**，朗读场景直接不可用 |
| A7 | `youtube_player_view.dart:130/170` | 250 ms 轮询 | ❌ 同类问题（墨水屏不看视频，只保留音频） |
| A8 | 约 40 处引用（主体 `shared/widgets/loading_indicator.dart`） | `CircularProgressIndicator` 旋转 | ❌ 旋转 = 每帧刷新，屏幕上就是一直在"抖" |
| A9 | `app.dart:175-197` + `app_theme.dart` | Material3 主题：ink splash / elevation / 半透明 | ❌ 水波纹、点击高亮、卡片阴影全是多余刷新 |
| A10 | 全局（无 `RawKeyboard`/`HardwareKeyboard`） | **无任何物理键支持** | ❌ Leaf 5C 的实体翻页键完全用不上 |
| A11 | `settings.dart:28` `enableTooltipCaching=false` | 每次点词都是裸网络请求 | ❌ 出卡延迟被网络放大，墨水屏上格外难受 |
| A12 | `text_display.dart:160-189` | 状态用**彩色底块 + 彩色字** | ❌ 彩色层半分辨率下糊；切灰阶后又分不出来 |
| A13 | 默认 `autoPronounceOnTap=true` | 点词自动发音（常走网络 TTS） | ⚠️ 网络 TTS 延迟叠加，建议 eInk 下默认关 |

✅ 已经做对的：每个词都包了 `RepaintBoundary`（`text_display.dart:192/217`）；播放行高亮用集合比对、只在句子切换时滚动（`text_display.dart:556-568`）；`pageTurnAnimations` 开关已存在；`AndroidManifest.xml` 已声明 `POST_NOTIFICATIONS`（Android 13 必需）✅；代码里**没有 hover 相关 UI**，手写笔悬停不会触发重绘。

---

## 3. 改造方案

优先级：**P0 = 不改架构、收益最大**；P1 = 需新增/调整主题与预设；P2 = 已降级为"不做"（系统侧已提供）。

### P0-1 新增「墨水屏模式」总开关（约 60 行）

- `features/settings/models/settings.dart`：加 `final bool eInkMode;`（默认 `false`），补齐 `copyWith` / `==` / `hashCode`（这文件三者必须同步改，漏一个会导致设置不生效或重建异常）。
- `features/settings/providers/settings_provider.dart`：持久化 + `updateEInkMode(bool)`，按现有 `updateXxx` 写法。
- `features/settings/widgets/settings_screen.dart`：放在 **Reading** 分区，配一句说明。
- 新增 `shared/theme/eink.dart`：导出 `eInkEnabledProvider`（从 settings 派生）+ 工具 `einkDur(context, ms)`（eInk 下返回 `Duration.zero`）、`einkShadow(context, shadow)`（eInk 下返回 `null`）。后续各点统一用它，避免散落 `if`。

### P0-2 主题层统一去动画（约 30 行）

`app.dart` 里 eInk 打开时给 ThemeData 叠加：

- `splashFactory: NoSplash.splashFactory`，`splashColor/highlightColor/hoverColor: Colors.transparent`
- `pageTransitionsTheme`：全部平台用自建 `NoTransitionsBuilder`（`buildTransitions` 直接返回 child）
- `elevation` 归零（`cardTheme`、`elevatedButtonTheme`）——阴影在墨水屏只会变脏

### P0-3 加载指示静态化（约 20 行 + 5 处替换）

`shared/widgets/loading_indicator.dart` 在 eInk 下返回**静态文案/骨架块**，不返回 `CircularProgressIndicator`。
阅读路径上散落的几处（`term_form.dart`、`sentence_translation.dart`、`dictionary_view.dart`、`settings_screen.dart`、books 列表刷新）同样替换；非阅读路径可后补。

### P0-4 阅读页刷新面收口（约 40 行）

- `reader_screen.dart:1339` 拖动跟手：eInk 下**不跟随位移**（`_dragOffset` 恒 0），保留手势识别但只在松手时翻页（见 D3）。
- `reader_screen.dart:1351`：`pageTurnAnimations` 在 eInk 下强制 `false`。
- `reader_screen.dart:684/701/734` 三处 `AnimatedContainer` 的 duration 走 `einkDur()`。
- `text_display.dart:122-138`：eInk 下 `boxShadow` 置空，高亮改用**纯色底块或下边框**。
- `text_display.dart:602`：`ensureVisible` 的 duration 走 `einkDur()`。

### P0-5 关掉 250 ms 心跳（约 25 行）— 朗读能否可用的关键

- `tts_player_provider.dart:555`：eInk 下**不启动** position timer；播放条改为"句序 + 播放/暂停/上下句"，**不显示秒级进度**。
- `youtube_player_view.dart`：eInk 下停掉 250 ms 轮询，只保留音频与字幕句子切换事件。

### P0-6 物理翻页键（新增约 120 行）

- 新建 `shared/widgets/hardware_key_navigator.dart`：`Focus(onKeyEvent:)` 包住页面，捕获 `volumeUp / volumeDown / pageUp / pageDown / space`，转成语义回调。
- 接线：`reader_screen` → 上一页/下一页；`sentence_reader_screen` → 上一句/下一句（**第二处同逻辑别漏**）。
- **加"按键诊断"入口**（设置页长按版本号进入）：显示最近一次按键的 `logicalKey`/`keyLabel`。
  用途：确认 Leaf 5C 翻页键实际发的是**音量键**还是 **PageUp/PageDown**——BOOX OS 4.1 的"应用优化 → 按键设置"可把物理键映射为音量键或翻页键，两种都要兼容。
- 风险：部分机型音量键只给 `keyUp`，且系统可能同时调音量；返回 `KeyEventResult.handled` 可吞掉，需真机验证。

### P0-7 手写笔（**结论：不需要改代码**，仅确认）

- Android 把笔当作触摸事件派发，笔尖点词与手指点词走同一条路径，现有 `GestureDetector` 直接可用 ✅
- 代码里无 `MouseRegion`/hover 逻辑 → 笔悬停不会触发重绘 ✅
- 待实测：笔身按键/橡皮是否发 keycode；若有，并入 P0-6 的按键诊断一起确认（可作为"朗读当前句"快捷键）
- 不做：笔标注/手写输入（本 app 无此功能）

### P1-1 E-Ink 主题预设（约 150 行）

`shared/theme/theme_definitions.dart` 新增 `einkThemePreset`：

- 纯 `#FFFFFF` 底 / `#000000` 正文（**推荐浅色**：墨水屏全刷时黑白反转闪更明显）
- 状态不再靠色相，改为 **4 级灰底 + 字重/下划线**（见 D2）
- `playingLineHighlight` 从"色块"改"下边框"；`wordGlowColor` 场景直接关闭
- `app.dart:175-197`：`ThemeType` 增加 `eink`，或 eInk 打开时强制走该 preset（见 D1）

### P1-2 排版预设（约 40 行）

针对 1264×1680 / 300 ppi：正文默认字号 +2、行距 1.7、左右边距 24（左侧更宽避开握持区）、底部留 64；`fullscreenMode` 默认开；`showPageNumbers` 默认关；词热区 padding 2 → 4（`text_display.dart:174`）降低误点。

### P1-3 一键预设（约 40 行）

设置页加「应用墨水屏预设」按钮，一次写入：`eInkMode=true`、`enableTooltipCaching=true`（磁盘缓存 + 整页预取）、`showTooltipImages=false`、`autoPronounceOnTap=false`、`enablePagePreload=true`、`pageTurnAnimations=false`。配一个「恢复默认」。

### P2 原生 E-Ink 刷新 API —— **建议不做（已降级）**

原本设想用 MethodChannel + 反射文石 `EpdController` 实现"每 N 页强制全刷"。
调研结论：BOOX OS 4.1 的 **EinkWise / 应用优化已在系统层提供**——刷新模式（Regal/HD/Speed）、**全刷频率**、**动画过滤**、漂白分页，还支持导出配置码。系统层做这件事更稳、零维护成本、无机型耦合。
**因此：不写代码。** 需要"立即全刷"时用文石的系统刷新手势。

---

## 4. 执行批次（每批独立可验证）

| 批次 | 内容 | 产出 | 验证方式 |
|---|---|---|---|
| B1 | P0-1 + P0-2 + P0-3 + P0-4 | 一个"静止不抖"的阅读页 | 真机翻页目视 + 静止 5 s 无重绘 |
| B2 | P0-6 物理键 + 按键诊断（含 P0-7 笔键确认） | 翻页键可用 | 短按/长按实测 + 诊断页读 keycode |
| B3 | P0-5 + P1-3 | 朗读可用、点词不等待 | 朗读 30 s 数刷新次数；点词计时 |
| B4 | P1-1 + P1-2 + 文档 | 观感与排版定型 | 连续翻 20 页看残影与可读性 |

每批按现有流程：`flutter analyze` → 按文件跑 `flutter test`（**不要整目录跑，会挂**）→ 生产机 `/opt/build_apk.sh` 出包 → CDN 下载（**文件名带时间戳**，否则命中 CF 缓存拿旧包）→ 装机。

---

## 5. 待你拍板

| # | 问题 | 选项 | 我的推荐 |
|---|---|---|---|
| D1 | 开关形态 | ① 运行时开关（一个 APK，默认关）<br>② 编译期 flavor / `--dart-define`（两个 APK） | **①**：一套代码一份包，手机与墨水屏互不干扰 |
| D2 | 状态怎么表达（放弃色相后） | ① 4 级灰底 + 未学加粗<br>② 灰底 + 下划线（实/虚/点）<br>③ 只留"未学/已掌握"两态 | **①**：只改 preset 色值；② 需自绘边框，会影响行高与基线 |
| D3 | 翻页交互 | ① 保留拖动但松手才换页 + 物理键<br>② eInk 下禁用拖动，改左右区域点击<br>③ 只用物理键 | **①**：保留肌肉记忆；系统侧"动画过滤 0"还能兜底 |
| D4 | 朗读进度 | ① eInk 下彻底停 250 ms tick，播放条不显示秒级进度<br>② 降频到 1 s | **①**：1 s 仍是每句数次闪；墨水屏上"第几句"比"第几秒"有用 |
| D5 | ~~原生刷新 API~~ | — | **已取消**：BOOX OS 4.1 系统层已提供全刷频率与动画过滤，见 P2 |
| D6 | 🆕 手写笔 | ① 只当触摸用（零成本）<br>② 额外支持笔身键翻页 | **①**：先按零成本处理，笔键等按键诊断实测后再决定 |

两个小确认：
- **系统 TTS 引擎语种**：Android 13 国行 BOOX 自带 TTS 未必含日语/韩语。建议墨水屏场景默认走**服务端 TTS**（`TTSProvider.edge`，经 Lute 服务端 `/tts/<lang>/<text>`）+ 蓝牙耳机。
- **选配笔是否已买**：不影响方案，只影响热区大小（无笔时热区 padding 加到 4，有笔可保持 2）。

---

## 6. Leaf 5C 系统侧配置清单（不写代码，装机后设一次）

> BOOX OS 4.1：E-Ink 中心已升级为 **EinkWise**，支持**按 App 单独配置**，并可导出/导入配置码（调好后存一份到本文档，换机重装可一键导入）。

1. **EinkWise**（控制中心 → EinkWise，在 Lute 界面下配置）
   - 刷新模式：**Regal**（第三方 App 推荐，残影最少；嫌慢可改 HD/Normal）
   - 色彩模式：Standard / Optimal（看漫画时再切 Vivid）
   - 布局：Original；图像平滑：**关**（纯文字）
2. **应用优化**（针对 Lute，最关键）
   - 刷新模式：**Regal**
   - **全刷频率：10**（残影敏感就 5；20 也可）——即每翻 10 页全刷一次清残影
   - **动画过滤：0** —— 让系统略过 App 内的过渡帧，翻页变"瞬间切换"，消除拖影
   - 漂白分页：文字描边 0 / 图标颜色 0 / 封面颜色 0 / 背景颜色 0
   - E-Ink 中心：深色增强 **50**（纯文字更黑更清晰）
   - 按键设置：启用自定义按键，物理键映射为**上一页/下一页**（与 P0-6 配合；若 app 侧已接管则设为音量键以免重复响应）
3. **开发者选项**：窗口动画缩放 / 过渡动画缩放 / 动画时长缩放 → 全部关闭
4. **前光**：多级双色温，白天关、夜间开暖光低亮度
5. **侧载**：Android 13 需先给来源 App 授权"允许安装未知应用"；`adb install -r` 亦可（保留服务器地址与凭据）
6. **续航**（2000 mAh）：开 tooltip 磁盘缓存、关点词自动发音、TTS 走服务端 + 蓝牙、不启用 Termux 集成（该设备上没有 Termux）
7. **配置码**：调好后导出 EinkWise 配置码，贴回本文档 §6 存档

---

## 7. 验收清单（真机）

- [ ] 翻一页：目视只闪 **1 次**；不翻页时屏幕完全静止
- [ ] 静止 5 s 无任何自发重绘（debug 包 + Repaint Rainbow 目视，或 `dumpsys gfxinfo` 看帧数）
- [ ] 朗读 30 s：刷新次数 ≈ 句子切换次数（不再每秒 4 次）
- [ ] 物理键：短按翻页生效、长按不误调音量、不与手势冲突
- [ ] 笔（若有）：笔尖点词生效，悬停不触发刷新
- [ ] 点词出卡 < 300 ms（预取开启后）
- [ ] 连续翻 20 页：残影可接受，每 10 页自动全刷一次（验证系统全刷频率生效）
- [ ] 状态栏/顶部条无随时间变化的文案（时钟、倒计时、连接心跳都会持续刷新）
- [ ] 30 分钟阅读掉电 < 10%（2000 mAh）
- [ ] 关掉 eInk 模式后，手机端行为与之前完全一致（回归点）
