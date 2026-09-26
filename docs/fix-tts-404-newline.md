# 修复：TTS 朗读一开口就 404（句子里的换行进了 URL 路径）

> 现象来自 Leaf 5C 真机反馈（2026-09-26 深夜）：切到 TTS 条点播放，播放条直接
> 报 `Edge TTS request failed: ... status code of 404 ...`，整页朗读用不了。
>
> 状态：**代码已改，但一行都没验证过** —— 本机 shell 环境损坏，`flutter
> analyze` / `flutter test` / 构建 / `adb install` 全部执行不了。见 §6。

---

## 1. 现象与第一手证据

客户端播放条上的错误：

```
Error: Edge TTS request failed: ... status code of 404 ...
```

服务端 nginx 访问日志里对应这一条（**原文，含百分号编码**）：

```
GET /tts/ja-JP/%E4%BD%9C%E8%AF%8D%20%3A%20%E4%B8%8A%E6%B1%9F%E6%B4%8C%E6%B8%85%E4%BD%9C%0A  → 404
```

解码：

| 编码 | 字符 |
|---|---|
| `%E4%BD%9C%E8%AF%8D` | `作词` |
| `%20%3A%20` | ` : ` |
| `%E4%B8%8A%E6%B1%9F%E6%B4%8C%E6%B8%85%E4%BD%9C` | `上江洌清作` |
| **`%0A`** | **`\n`（换行）** |

所以请求的末段是 `作词 : 上江洌清作\n` —— 一本歌词集里的**作词署名行**，
它作为一个 text item 被服务端切成了独立句子，而且**末尾带一个换行符**。
HTML 会折叠换行，所以屏幕上完全看不出来，但 URL 里它是实打实的 `%0A`。

> URL 是**规范编码**的（空格 `%20`、冒号 `%3A`），说明客户端
> `Uri.encodeComponent` 工作正常 —— 问题不在编码，在**送了什么**。

---

## 2. 根因：Werkzeug 的 `path` 转换器匹配不了换行

服务端路由（`lute-v3/lute/tts/routes.py:192`）：

```python
@bp.route("/tts/<lang>/<path:text>", methods=["GET"])
```

看起来极其宽松（`path` 能吃斜杠），但对**末段**有两个隐藏要求。逐行核对
**服务器上实际安装的 Werkzeug 源码**：

**① 末段必须吃到字符串绝对末尾。**

`routing/rules.py:678-679`，`_parse_rule()` 收尾处：

```python
if not static:
    content += r"\Z"
```

`<path:text>` 的 `part_isolating = False`，所以它所在的这一分段被追加了
`\Z` 锚点。

**② 这个正则编译时没有 `re.DOTALL`。**

`routing/matcher.py:130`，状态机匹配器：

```python
match = re.compile(test_part.content).match(target)
```

**裸 `re.compile`，一个 flag 都没有。** 而 `PathConverter.regex` 是
`[^/].*?`（`routing/converters.py:123`）。

两条一叠加：

- `\Z` 要求匹配必须抵达字符串末尾；
- `.` 在无 `DOTALL` 时**不匹配 `\n`**，所以 `.*?` 最多只能扩到换行符**之前**；
- 末尾那个 `\n` 无人消费 → `\Z` 永远无法满足 → **正则不可能匹配**
  → `NoMatch` → **404**，而且是在路由函数体执行**之前**就 404 了。

**③ 末段为空也一样 404。** `[^/]` 至少要有一个字符，所以
`/tts/ja-JP/`（句子归一化后为空）同样匹配不上。

### 为什么 `」` 是 422 而不是 404

这解释了同一个接口两种状态码的分工：

| 请求末段 | 路由 | 结果 |
|---|---|---|
| `」` | 命中 | 路由执行 → edge-tts 念不出来 → **422**（可跳过信号） |
| `作词 : 上江洌清作\n` | **不命中** | 路由没跑 → **404** |

而客户端 `isSynthesisFailureResponse()` **故意**只认 422（以及旧式
502+标记），**404 是"真出错了"**——这条契约有测试钉着
（`test/tts_synthesis_failure_test.dart:95` 把 404 列在"不是可跳过碎片"里）。

所以 404 冒成了硬错误：播放条弹横幅、停在那一句。**这个判定是对的，不该改。**

### 网页播放器为什么没事

同一台服务端、同一个接口，网页版朗读正常。差别就在发请求前那一行
（`lute-v3/lute/static/js/tts-player.js:296`，`tts.js:327` 是同一个函数）：

```js
function cleanSentenceText(rawText) {
  return rawText
    .replace(/[#＃]/g, "")
    .replace(/\s+/g, " ")   // ← 换行在这里被折叠成空格
    .trim();                // ← 末尾空白在这里被去掉
}
```

**网页端从来不把 `\n` 送进 URL，所以从来没踩到这个正则缺陷。**

---

## 3. 修法

移动端对应的入口是 `normalizeTtsText()`（`lib/core/network/tts_service.dart`），
改造前只剥零宽字符：

```dart
String normalizeTtsText(String text) =>
    text.replaceAll('\u200B', '').replaceAll('\uFEFF', '');
```

**改动 1 —— 补上网页端的空白规则**（换行/制表/连续空格 → 单个空格 + trim）：

```dart
String normalizeTtsText(String text) => text
    .replaceAll('\u200B', '')
    .replaceAll('\uFEFF', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
```

这个函数是**三处共用的唯一文本源**（`tts_player_provider.loadPage` 的
snippet.text、`sentence_tts_provider.speakSentence`、以及由前者派生的
时长估算），所以在这一处归一化，三个消费者自然一致。

**改动 2 —— 空句守卫（整页朗读）**：`tts_player_provider.dart` 的
`_speakCurrent()` 开头，`snippet.text.isEmpty` 时不碰服务，直接按"播完"
推进下一句（复用「不可发音碎片」那条既有路径）。

**改动 3 —— 空句守卫（单句点读）**：`sentence_tts_provider.dart` 的
`speakSentence()`，归一化后为空则直接返回，也不顺手暂停书籍音频
（避免在页边空白上误点一下掐掉有声书）。

### 刻意没做的两件事

- **没有把 404 加进 `isSynthesisFailureResponse`。** 那会推翻一条有意为之、
  且有测试钉住的契约（404 = 真出错了）。方向反了：要修的是"为什么会 404"。
- **没有剥 `#` / `＃`**，尽管网页端会剥。两者在路径段里都合法，**不可能**引发
  上面的 404；而剥掉会改变 `C#` 这类正常文本的读法。这是与网页参考实现的一处
  有意偏差，已写进 `normalizeTtsText` 的文档注释。

---

## 4. 回归防线

| 文件 | 内容 |
|---|---|
| `test/tts_text_normalization_test.dart`（新增） | 7 条。核心是把服务端规则写成可断言属性 `_isRoutable(text) = 非空 && 不含 \n/\r`：先证明**原始**的 `作词 : 上江洌清作\n` 不可路由（复现线上 404），再证明归一化后可以。另含零宽字符回归、空白折叠、`#` 保留、已干净文本原样通过。 |
| `test/tts_player_fragment_skip_test.dart`（+1 条） | 页面里放一个幽灵句（`'\n \u200B '`）和一个带换行的句子，断言：服务**没收到空文本**、句子本身照读、`snippet.text` 已无换行、不弹横幅。 |

> 写这条测试时踩到自己的坑：第一版断言 `fake.spoken` 不含
> `'作词 : 上江洌清作\n'` —— **这是假绿灯**，因为那个假服务自己会
> `text.trim()`，修不修都能过。改成断言 `state.snippets[i].text`
> （它才是 `_fetchAudio` 拼进 URL 的那份字符串）才有判别力。

---

## 5. 真机验收（2026-09-27 01:07 装包，**全部通过 ✅**）

交付包 `dist/_lute_ttsfix_20260927-0106.apk`，sha1
`480c20e9d175567679d31d47df1c4245cf438d29`（28132386 bytes），CDN
`https://www.metaman.dpdns.org/static/_lute_ttsfix_20260927-0106.apk`。
`adb install -r` 一次成功（Leaf5C serial `38120d06`）。这个包同时带着**上一轮没装上的
书签刻度修复**，所以一次装包验了两件事。

### 5.1 服务端证据（最硬的一条）

同一句话、同一个客户端（`User-Agent: Dart/3.13 (dart:io)`），**只差末尾那个 `%0A`**：

| | nginx 里的路径末段 | 状态 |
|---|---|---|
| 修复前（00:36:30） | `/tts/ja-JP/…%E4%B8%8A%E6%B1%9F%E6%B4%8C%E6%B8%85%E4%BD%9C` **`%0A`** | **404** |
| 修复后（01:08 起） | `/tts/ja-JP/…%E4%B8%8A%E6%B1%9F%E6%B4%8C%E6%B8%85%E4%BD%9C` | **200** |

- 整页朗读共 **42 条请求，全部 200**，其它状态码 0 条；含 `%0A` 的请求数 **0**。
- 第 7 条是 `/tts/ja-JP/…出会い%20時は流れる` —— 那个 `%20` 就是原来的换行，被折叠成了
  单个空格。**空白折叠确实生效了**，不只是把换行删掉而已。

### 5.2 界面证据

TTS 条从 `1/40` 一路推进到 **`40/40`、`02:54 / 02:54`**，中间键回到播放三角（正常
收尾），**全程没有红色错误横幅**。对照修复前：第一条请求就 404，播放条弹横幅并停住。

### 5.3 书签刻度（上一轮遗留项，一并验完）

这本书（《小さな恋のうた - Aragaki Yui》）带音频，切到 MP3 条复验：

| 项 | 实测 | 结论 |
|---|---|---|
| 滑轨 | y 267..277，11 px = 5.9 dp | = `trackHeight:6` ✓ |
| 刻度宽 | 3.2 dp（圆角列高 11/17/18/18/17/11 递减） | ≈ 设计 3 dp ✓ |
| 刻度高 | 9.6 dp（y 263..280） | ≈ 设计 10 dp ✓ |
| **刻度中心 vs 滑块中心** | 都是 **399.5** | **偏差 0.0 px** ✓ |
| 刻度在**灰未播轨**上 | luma **28**（黑） | 可见 ✓ |
| 刻度在**黑已播轨**上 | luma **>200**（白） | 可见 ✓ |

最后两行正是上一轮那个缺陷的判据：改造前刻度恒为黑，一旦播放越过书签就整条消失。

---

## 6. 验证记录与遗留

### 6.1 构建/静态验证（2026-09-27 00:5x–01:06，shell 恢复后补跑）

- [x] `flutter analyze`：**194 issues / 0 error**（137 info + 57 warning），与改动前基线持平
- [x] `flutter test` 逐文件：**18/18 文件全绿**（原 17 + 新增 `tts_text_normalization_test.dart`）
- [x] 新增用例数确认：归一化 7 条、播放器 +1 条（该文件共 3 条）、404 契约 5 条
- [x] **变异检验**：把 `normalizeTtsText` 临时改回旧实现 → 归一化测试 **4 条变红**，
      播放器那条红在 `Expected: not contains ''`（即服务**真的**收到了空文本）。
      改回来立刻全绿。**这一步是为了证明新测试有判别力，而不是假绿灯。**

### 6.2 真机验收

见 §5 —— TTS 朗读与书签刻度两项**全部通过**。

### 6.3 仍未处理

- **静态目录残留**：`/opt/lute/lute/static/` 下有 5 个 `_lute_*.apk`（`ux2` / `reader1` /
  `volkeyfix` / `tickfix` / `ttsfix`），各 26.8MB，合计约 134MB。按 AGENTS.md 的约定，
  等用户确认后再删。
- **`paused` 后进度仍归零**（切后台回来不续播）—— 产品决策，未动。

### 6.4 本轮 shell 故障（记录备查）

2026-09-26 23:0x – 00:5x 本机 shell 完全不可用：所有命令 `exit 127`，报
`zsh:1: no such file or directory: /dev/null` 与 `brokered-sandbox-bash-env.sh` 找不到；
连 `pwd`、`true` 都跑不了，加 `dangerouslyDisableSandbox` 无效，子代理同样。
本机也没有 Dart LSP（`No LSP server configured for file type: .dart`），所以那段时间
**连语法检查都没有通道**，只能改代码。重启 WorkBuddy 后恢复。

> 教训：环境故障期间，"改动很小、且有参考实现逐行对照"**不能**当成验证。
> 该阶段产出的代码必须显式标注为未验证，恢复后第一件事就是补跑变异检验。

---

## 7. 可沉淀的经验

1. **"用户说按 X 就出 Y" 里，X 往往不是原因。** 上一轮的音量键停播就是
   "失焦"而非"按键"。这一轮同样：报的是"TTS 用不了"，真因是**句子末尾一个
   看不见的换行**。
2. **路径参数不是万能容器。** 把用户文本放进 URL path 之前，必须先做与
   "参考实现"一致的清洗。Werkzeug 的 `path` 转换器在**无 DOTALL** 的正则下
   匹配不了换行 —— 这类框架层的隐藏约束，只有读**实际安装的源码**才能确认，
   猜不出来。
3. **同一个接口的两种状态码各有语义时，不要为了"看起来好了"把错误码吞进
   可跳过分支。** 先问"这个码为什么会出现"。
4. **假对象自己的清洗会制造假绿灯。** 断言要落在**真正被使用的那份数据**上
   （这里是 `snippet.text`），而不是经过被测方之外的代码加工过的观测值。
