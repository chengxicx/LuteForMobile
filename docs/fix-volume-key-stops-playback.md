# Bug：MP3 播放中按实体音量键，播放停止且进度归零

**设备**：BOOX Leaf 5C（`38120d06`，Kaleido 3，1264×1680 物理 / 674dp 逻辑宽）
**反馈时间**：2026-09-26
**用户原话**：「我遇到了一个新的问题，在播放的时候如果按音量键就会导致播放停止。」

---

## 结论（一句话）

根因**不是音量键**，而是「**窗口失焦**」。

`reader_screen.dart` 的 `didChangeAppLifecycleState` 把 `inactive` 也当成「离开 app」，
于是任何让 Flutter 窗口失焦的系统行为都会把 MP3 播放器 `reset()` ——
**停止播放 + 进度清空到 0**。音量面板只是触发方式之一。

---

## 完整因果链

```
按音量键 / 下拉控制中心 / 权限弹窗 / 分屏拖动
        │
        ├─► 系统音量面板（或控制中心）弹出，Flutter 窗口失焦
        │
        ▼
AppLifecycleState.inactive
        │
        ▼
reader_screen.dart  didChangeAppLifecycleState
        } else if (state == paused || state == inactive) {
          ref.read(audioPlayerProvider.notifier).reset();   ← 元凶
        }
        │
        ▼
audio_player_provider.dart  reset() → _reset()
        _bookId = 0;  lastLoadSignature = null;  _stopSafely();   ← 播放停止
        │
        ▼
下一帧 AudioPlayerWidget.build 的 postFrameCallback
        notifier.lastLoadSignature(null) != loadSignature  →  重新 loadAudio()
        │
        ▼
从 audioCurrentPos（服务器记录，本次为 0）重新装配
        → 播放不会自动恢复，进度停在 0
```

### logcat 佐证

```
00:11:00.699  out_set_volume: left_vol=0.037584      ← 音量键按下，音量变化
00:11:00.789  NuPlayerDriver: pause(0xeb401ff0)      ← 90ms 后播放被暂停
00:11:03.791  NuPlayer: restartAudio timeUs(0)       ← 恰好 +3.0s，从 0 重新装配
```

`pause` 与 `restartAudio timeUs(0)` 的间隔稳定为 **3.000 秒**，
对应 `AudioPlayerWidget` 重新 `loadAudio()` 里探测/拉取音源文件的耗时。

---

## 判定实验：是「失焦」而不是「音量键」

| 操作 | 播放是否被重置 |
|---|---|
| 播放中按音量键（`input keyevent 25`） | **是** —— 已播段 249px → 34px（回到 0%） |
| 播放中下拉控制中心（`input swipe 632 8 632 1000`） | **是** —— 进度回到 `00:00` |
| 播放中什么都不做（对照，9 秒三次采样） | 否 —— 已播段 139 → 179px 稳定推进 |

下拉控制中心跟音量键毫无关系，却复现同一现象 ⇒ 触发条件是**窗口失焦**，
音量键只是恰好会弹出系统音量面板。这也解释了为什么用户会觉得「按音量键就停」。

---

## 修法

只把 `paused` 当成「真的离开 app」，`inactive` 不再停播放：

- 新增 `lib/features/reader/utils/player_lifecycle.dart`
  ```dart
  bool shouldStopAudioOnLifecycleChange(AppLifecycleState state) {
    return state == AppLifecycleState.paused;
  }
  ```
- `reader_screen.dart` 的 `else if` 改为调用它。
- 新增 `test/player_lifecycle_test.dart` 钉住这条契约（inactive 不停、paused 仍停）。

**为什么去掉 `inactive` 是安全的**：切后台的完整序列是
`inactive → hidden → paused`，真正离开 app 仍然会被 `paused` 兜住。

**为什么不连 `hidden` 一起处理**：`hidden` 只是过渡态，紧随其后的 `paused`
才是终点；多接一个只会增加误停的机会。

---

## 验收（真机）

- [ ] 播放中按音量键 → 播放**继续**，进度不归零
- [ ] 播放中下拉控制中心 → 播放**继续**
- [ ] 播放中按 Home 键 → 播放**停止**（确认 `paused` 仍然生效，没把该停的漏掉）

---

## 顺带记录：本次没改但值得留意

1. **`paused` 之后进度归零而不是「记住位置待恢复」**：现在切后台再回来，
   播放位置回到服务器记录值。对有声书来说更好的行为是记住本地位置、
   回来后接着播。这是独立的产品决策，本次不动。
2. **`reset()` 会连带清掉 `lastLoadSignature`**，导致 `AudioPlayerWidget`
   下一帧无条件重新 `loadAudio()`。这个「reset 后自动重装」的联动是
   上面 3 秒延迟的来源，也让任何一次误 reset 的代价被放大。
3. **`sentence_reader_screen.dart` 没有这个问题** —— 它的
   `didChangeAppLifecycleState` 只处理 `resumed`，不碰播放器。
