# TTS「空白音频 / 朗读卡住」问题 — 交接文档（Handoff）

> 用途：把当前进度与环境操作流程完整交给下一个模型/人，无需回溯聊天记录即可接手。
> 最后更新：2026-09-23（第二轮：根因已定位为 Cloudflare 改写 502 响应体）

---

## 0. 一句话现状

Lute 手机端（Flutter，`LuteForMobile`）用 Edge TTS 朗读，TTS 请求走自建 Lute 服务端
（`lute-v3`，部署在 `172.236.226.132`）的 `/tts/<lang>/<text>` 接口。

**根因（已证实）**：站点在 **Cloudflare** 后面，CF 会把**源站 5xx 的响应体整个替换掉**。
服务端原来用 `502 + {"error":"tts synthesis failed"}` 表示「这段文字念不出来」，
客户端靠**匹配这个 JSON 标记**来识别；但经 CF 后变为
`502 + "error code: 502"`（16 字节纯文本），标记永远匹配不上 → 客户端抛通用
`TTSException('Edge TTS request failed: …')` → 播放条打出**红色横幅（Dio 原始异常文本）**
并**停在那一句不再前进**（实测卡在《横浜のアパートの惨劇》第 **7/33** 句，
该句被切成只剩一个 `」`）。

**已修并已部署**：
- 服务端：改用 **422**（4xx 响应体 CF 不改写）→ commit `45041f19`，已推 `my`、已快进合并到
  `/opt/lute`、已 `systemctl restart lute`。经 CF 实测：`422 / 33 B / application/json / {"error":"tts synthesis failed"}` ✅
- 客户端：`_fetchAudio` 接受 **422**（并保留 502+标记 的向后兼容）→ 见 §3.2。
  **真机验证已通过**：整页 33 句读完（`33/33`、无横幅），本次请求 30×200 + 3×422、其它错误 0。

> ⚠️ 上一版本文档的两条结论是**错的**，不要再采信：
> 1. 「红色错误横幅已消失」——横幅一直在，只是位置在播放条**顶部**，截屏区域偏低就会看不见（见 §8）。
> 2. §5 里猜的两种解释 (A)「APK 滞后」/(B)「另一条路径不补发 completion」——**都不是**。
>    实测已装 APK 里就有修复字符串（§8 有验证方法），且整页朗读走的
>    `_speakCurrent` 已经 `on TTSUnpronounceableFragmentException` 就推进。

---

## 1. 工作环境 / 访问

### 1.1 本机（Mac，跑 WorkBuddy 的机器）
| 项 | 路径 |
|---|---|
| 客户端源码 | `/Users/cxi/Documents/lutedev/LuteForMobile` |
| 服务端源码 | `/Users/cxi/Documents/lutedev/lute-v3` |
| adb 工具 | `/tmp/platform-tools/adb` |
| SSH key（**临时，见下**） | `/tmp/sshx/id_rsa`（含 `known_hosts`） |

> ⚠️ **`/tmp/sshx/` 在 /tmp 下，重启或清理后可能丢失。** 接手第一步先确认 key 还在。
> 连接参数：`ssh -i /tmp/sshx/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/sshx/known_hosts root@172.236.226.132`
>
> ⚠️ **本机没有 Flutter/dart**（`which flutter` 为空）。所有 `flutter analyze/test/build`
> 都必须 SSH 到生产机上跑（`/opt/flutter`）。好消息：`flutter test` 很轻量，**改状态机逻辑时
> 优先用「同步源码 + 跑 test」迭代，别每轮都编 APK**（一次 APK 构建 6–20 分钟）。

### 1.2 生产机 `172.236.226.132`
| 项 | 值 |
|---|---|
| 系统服务 | `lute`（Flask 后端）、`nginx`、`mariadb`（均 `systemctl`）|
| 服务端代码 | `/opt/lute`（即 `lute-v3`，当前 `45041f19`）|
| 服务端启动命令 | `/opt/lute/venv/bin/python3 -m lute.main --local --port 5001` |
| **改服务端代码后必须** | `systemctl restart lute`，**启动约需 10 秒**才监听 5001（3 秒就去 curl 会得到 connection refused，别慌）|
| 客户端构建目录 | `/opt/lute_mobile_src`（每次构建前 `rm -rf` 重建）|
| Flutter | `/opt/flutter`；`PUB_CACHE=/opt/flutter/.pub-cache` |
| 构建脚本 | `/opt/build_apk.sh`（`flutter build apk --release --target-platform android-arm64`）|
| 静态文件交付 | `/opt/lute/lute/static/`（APK 临时放这里，再走 nginx 下载）|
| 外网域名 | `https://www.metaman.dpdns.org`（**在 Cloudflare 后面**）|
| nginx | 只监听 :80，`sites-enabled/default` → `proxy_pass http://127.0.0.1:5001`；**源站无 443**，TLS 由 CF 终结 |
| nginx 访问日志 | `/var/log/nginx/access.log`（TTS 请求形如 `GET /tts/...`，这里是最好用的外部仪表）|

### 1.3 安卓手机（被测设备）
| 项 | 值 |
|---|---|
| 包名 | `com.schlick7.luteformobile` |
| 测试书 | 《横浜のアパートの惨劇》（日文，共 33 句；**第 7 句是只剩 `」` 的碎片**）|
| 设备 | 会锁屏；解锁需要**用户自己输入 PIN**（`wm dismiss-keyguard` 不够，有 6 位密码）|
| 常用命令 | `adb shell screencap -p`、`adb shell uiautomator dump`、`adb install -r` |

---

## 2. 构建 & 部署流程（标准闭环）

```bash
# ① 本地源码打 tar 推到生产机并构建（排除重目录；本地不能编 APK）
cd /Users/cxi/Documents/lutedev/LuteForMobile
tar -cf - --exclude='./.git' --exclude='./.dart_tool' --exclude='./build' \
        --exclude='./dist' --exclude='./.workbuddy-ai' --exclude='.DS_Store' . \
  | ssh -i /tmp/sshx/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/sshx/known_hosts \
      root@172.236.226.132 '
        rm -rf /opt/lute_mobile_src; mkdir -p /opt/lute_mobile_src
        tar -xf - -C /opt/lute_mobile_src 2>/dev/null
        export FLUTTER_HOME=/opt/flutter; export PUB_CACHE=/opt/flutter/.pub-cache
        export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"
        cd /opt/lute_mobile_src
        flutter pub get > /tmp/pubget.log 2>&1
        flutter analyze > /tmp/analyze.txt 2>&1        # 收尾看 error 数
        flutter test test/tts_player_fragment_skip_test.dart \
                     test/tts_synthesis_failure_test.dart 2>&1 | tail -3
        cd /opt/lute_mobile_src/android
        cat > gradle.properties <<"EOF"
org.gradle.jvmargs=-Xmx1280m -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=128m
org.gradle.parallel=false
org.gradle.workers.max=1
org.gradle.daemon=false
org.gradle.caching=false
android.useAndroidX=true
android.enableJetifier=true
android.builtInKotlin=false
android.newDsl=false
EOF
        rm -f /tmp/build.log
        systemd-run --scope --collect -p MemoryMax=2400M -p MemorySwapMax=3G --unit=flutterbuild \
          bash -c "bash /opt/build_apk.sh > /tmp/build.log 2>&1; echo EXIT=\$? >> /tmp/build.log" >/dev/null 2>&1 &
        for i in $(seq 1 70); do grep -q "^EXIT=" /tmp/build.log 2>/dev/null && break; sleep 10; done
        tail -3 /tmp/build.log
        sha256sum /opt/lute_mobile_src/build/app/outputs/flutter-apk/app-release.apk
      '

# ② 经 nginx 下载 APK 到本机（比对 SHA 一致后再装）
ssh ... 'cp /opt/lute_mobile_src/build/app/outputs/flutter-apk/app-release.apk /opt/lute/lute/static/_lute_handoff.apk'
curl -sSL -o /tmp/app.apk "https://www.metaman.dpdns.org/static/_lute_handoff.apk" -w "http=%{http_code}\n"
/tmp/platform-tools/adb install -r /tmp/app.apk
ssh ... 'rm -f /opt/lute/lute/static/_lute_*.apk'   # 清理临时文件

# ③ 真机复验（看是否越过 7/33；同时看服务端是否继续被请求）
ssh ... 'grep -a "tts/" /var/log/nginx/access.log | tail -20'
```

> 生产机内存小：用 `systemd-run --scope -p MemoryMax=2400M` 限内存 + 关 gradle daemon。
> `flutter analyze` 的 error/warning/info 计数：`grep -oE "(error|warning|info) •" | sort | uniq -c`。

### 2.1 服务端改动怎么上线
```bash
# 本地
cd /Users/cxi/Documents/lutedev/lute-v3 && git add <file> && git commit && git push my all-features-combine
# 生产机（不要 reset --hard）
ssh ... 'cd /opt/lute && git fetch my && git merge --ff-only my/all-features-combine && systemctl restart lute'
# 等 ~10s 再验证
ssh ... 'systemctl is-active lute; ss -ltnp | grep 5001; curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5001/'
```

---

## 3. 代码改动状态

### 3.1 服务端（**已提交 / 已推送 / 已部署** ✅）
- 仓库 `/opt/lute` 与本地 `lute-v3` 都在 **`45041f19`**
  `fix(tts): answer 422, not 502, for an unsynthesizable fragment`
- 只改 `lute/tts/routes.py`：合成失败时 `return jsonify({"error": "tts synthesis failed"}), **422**`
  （原为 502），并写了长注释说明「为什么必须是 4xx」——**不要改回 502**。
- 历史：上一轮 `88a04efa` 修的是「失败留下 0 字节毒缓存」，那部分依然有效
  （路由会先删掉 0 字节文件再重试，写文件用 `.part` + `os.replace()`）。

### 3.2 客户端（**未提交的工作区改动**，含本次 TTS 修复 + 播放条功能 ⚠️）
`git status` 有一大片 `M`（54 个文件）。本次 TTS 修复只涉及 3 个文件：

| 文件 | 改动 |
|---|---|
| `lib/core/network/tts_service.dart` | 新增 `EdgeTTSService.isSynthesisFailureResponse(Response?)`（`@visibleForTesting`）：**422 → true**；502 → 再嗅 JSON 标记（兼容未升级的旧服务端）；其余 false。`_fetchAudio` 改用它判定，判定为真就抛 `TTSUnpronounceableFragmentException`。同步更新了异常类与 `speak()` 的注释（原文写 502）。 |
| `test/tts_synthesis_failure_test.dart` | **新增**：5 条契约测试，钉住「422/502+标记 → 跳过；不透明 502 / 200 / 401 / 404 / 500 → 真实错误」。 |
| `test/tts_player_fragment_skip_test.dart` | **新增**：假 TTS 服务驱动 `ttsPlayerProvider`，断言①遇碎片会推进到下一句且不弹横幅；②遇到真实错误必须停住并报错。 |

> 其余无关改动（TTS 播放条 + 语言过滤等）与本次修复混在同一工作树里，尚未 commit。
> 如需只验证 TTS 修复：要么整体一起测，要么先隔离——但注意别 stash 掉同功能的其他部分导致编译不过。

### 3.3 当前 `_speakCurrent` 的设计（**别再改回注入合成事件**）
```dart
try {
  await service.speak(snippet.text);
  ... 置 playing / 起计时器
} on TTSUnpronounceableFragmentException {
  _onServiceCompleted();      // 当作正常播完 → 推进下一句
} catch (e) { ... status = error, errorMessage = ... }
```
`EdgeTTSService.speak()` 现在**故意 rethrow** 这个异常，而**不再**往
`_playerStateController` 注入一个假的 `PlayerState.completed`。原因写在 `speak()` 的注释里：
那个合成事件是 broadcast stream，调用方一旦在「发出」与「投递」之间重新 subscribe 就会**被丢掉**，
播放反而卡死。**这个改动是对的，不要「简化」回去。**

---

## 4. 根因证据链（本次定案）

| 环节 | 事实 |
|---|---|
| 直连源站 80（带 session） | `502` · **33 B** · `application/json` · `{"error":"tts synthesis failed"}` ✅ |
| 经 Cloudflare（同 URL 同 cookie） | `502` · **16 B** · `text/plain` · `error code: 502` ❌ `Server: cloudflare` |
| 用项目自带 dio 复现客户端视角 | `status=502 type=badResponse`、`dataType=_Uint8ArrayView`、`containsMarker=false` |
| 客户端行为 | 抛通用 `TTSException` → `_speakCurrent` 置 `error` → 红横幅 + 停在第 7/33 句 |

服务端返回 422 后，同一 curl 立即变成
`422 · 33 B · application/json · {"error":"tts synthesis failed"}`（CF 保留响应体），
正常句子仍是 `200 · audio/mpeg`。

**一句话**：**不要用「5xx + 自定义响应体」做跨 CDN 的信号通道**——CF 会把 5xx 的 body 换掉。
状态码本身会被保留，所以改用**专用的 4xx**。

---

## 5. 验证结果（**全部通过 ✅ 2026-09-23**）

- [x] **真机复验通过**（APK `sha256 72fc1d5c…`，见 §2 流程构建/安装）
  - 打开《横浜のアパートの惨劇》阅读器 → 点播放 → 整页读完
  - **最终 `02:47 / 02:47 · 33/33`，中间按钮回到播放三角（正常收尾），全程无红色横幅**
  - nginx 侧本次播放共 **33 条请求 = 30×200 + 3×422，其它错误 0**；`」` 之后**继续**出现第 8、9…句请求
  - 片段 `」` 只产生 1 次 422，随后立即跳到下一句 —— **原来必断在这里，现在完全跳过**
- [x] `flutter analyze` 0 error（0 error / 63 warning / 137 info）
- [x] TTS 测试全绿（7 passed：5 项状态码契约 + 2 项状态机）
- [x] 服务端经 CF 实测：碎片 `422 / 33 B / application/json`；ja/en/ko/zh 正常句 `200 audio/mpeg`；0 字节缓存计数 0
- [ ] 客户端改动 `git commit`（**仍待办**：建议把 TTS 修复与「播放条功能」分开 commit，便于 review）
- [x] `docs/tts_empty_audio_diagnosis.html` 已补第六节（CF 改写 5xx 的定案 + 订正旧结论）

### 5.1 已发现但**本次未修**的问题（下次处理）
- **播放中点「下一句」会跳两句**：`tts_player_provider.next()/previous()/seekTo()` 会
  `_stopService()`，而 `EdgeTTSService.stop()` 里的 `_audioPlayer.stop()` 会让服务流发出
  `PlayerState.stopped`；`_subscribeService` 的监听把 `stopped` 也当成「播完」，
  此时 `_advanceOnComplete` 仍为 true、`status` 已被置成 `loading` → `_onServiceCompleted()`
  又推进一次。修法方向：只把 `completed` 当播完，或在显式 stop 时屏蔽紧随的 `stopped`。
  （未修是因为本次要验证的构建已在飞行中，避免同时改动更多行为。）

---

## 6. 关键文件速查

| 文件 | 位置 | 内容 |
|---|---|---|
| `lib/core/network/tts_service.dart` | `isSynthesisFailureResponse`（`_fetchAudio` 上方） | **422 → 跳过；502 → 再嗅 JSON 标记** |
| 同上 | `_fetchAudio` | DioException 里用它判定，抛出 `TTSUnpronounceableFragmentException` |
| 同上 | `speak()` | **rethrow** 该异常（不注入合成事件）；401 / connectionError → 友好 `TTSException` |
| 同上 | `getAudioBytes()` | `=> _fetchAudio(text)`，同样会抛该异常 |
| 同上 | 文件末尾 | `TTSException` / `TTSUnpronounceableFragmentException` 定义 |
| `lib/features/reader/providers/tts_player_provider.dart` | `_speakCurrent` | `on TTSUnpronounceableFragmentException → _onServiceCompleted()` |
| 同上 | `_onServiceCompleted` | 靠 `_advanceOnComplete` + `canGoNext` 决定推进 / 收尾 |
| `lib/features/reader/providers/sentence_tts_provider.dart` | `speakSentence` catch | 单句点读路径：识别该异常后静默重置，不显示横幅、不重试 |
| `lib/features/reader/widgets/tts_player_widget.dart` | `build` | `state.errorMessage != null` → 渲染**红色横幅**（在播放条顶部） |
| `lute/tts/routes.py`（服务端，已部署）| `tts_speak` | **422** + JSON；先删 0 字节毒缓存；`.part` + `os.replace()` |
| `test/tts_synthesis_failure_test.dart` | — | 422/502 判定契约（5 例）|
| `test/tts_player_fragment_skip_test.dart` | — | 状态机：跳过碎片 / 真实错误仍报错（2 例）|

---

## 7. 排查手法（本次验证有效，建议沿用）

1. **release APK 不打日志**：`debugPrint` 在 release 包里**不会进 logcat**
   （`adb logcat -d | grep flutter` 始终为空）。所以不要指望日志，改用下面这些**外部仪表**。
2. **首选仪表 = nginx access.log**：每条 TTS 请求都会留痕，能精确看出客户端「请求到第几句后断掉」。
   `grep -a "tts/" /var/log/nginx/access.log | tail -20`
3. **判断已装 APK 里到底有没有某个修复**（不用重编）：
   ```bash
   adb shell pm path com.schlick7.luteformobile
   adb pull <该路径> /tmp/base.apk
   unzip -o -q /tmp/base.apk -d /tmp/x
   strings -a /tmp/x/lib/arm64-v8a/libapp.so | grep -F "tts synthesis failed"
   ```
   Dart AOT 会把字符串字面量留在 `libapp.so` 里，**命中即说明修复确实在这个包里**。
4. **看客户端真实看到的 HTTP 响应**：直连源站 vs 经 CF 做对照——
   ```bash
   # 经 CF（先登录拿 session）
   curl -sS -c /tmp/ck.txt -o /dev/null -d "username=<u>&password=<p>" https://<域名>/login
   curl -sS -b /tmp/ck.txt -w "http=%{http_code} size=%{size_download} ct=%{content_type}\n" "<url>" ; cat <body>
   # 绕过 CF 直连源站（源站无 443，走 80 + Host 头）
   ssh ... 'curl -sS -o /tmp/o.bin -w "http=%{http_code} size=%{size_download} ct=%{content_type}\n" \
            -H "Host: <域名>" -H "Cookie: session=<值>" "http://127.0.0.1<path>"'
   ```
5. **截图裁剪不用 Pillow**（本机没装，`pip install` 会被 SIGTERM）：
   `sips -c <高> <宽> --cropOffset <Y> <X> in.png --out out.png`
   - ⚠️ **错误横幅在播放条顶部**，会把控件整体下移。要看横幅请裁 **y≈1400–1700**；
     只看控件（容易漏掉横幅）会裁到 y≈1700–2100。
6. **`uiautomator dump` 可能全空**：Flutter 的语义树偶尔不吐文本（本次见过 55 个 `text=""`），
   此时**以截屏为准**，别因为 dump 没内容就下结论。
7. **别用点击「中间按钮」来试探状态**：`isLoading` 时它绑的是 `() {}`（无操作），
   `playing` 时是 pause，只有 idle/paused/error 才是 play。想制造请求请用
   **「上一句」+「播放」**，再看 nginx 是否只多出一条 `」`。

---

## 8. 已踩过的坑（别再踩）

- **5xx + 自定义响应体不能跨 CDN**：CF 会把源站 5xx 的 body 换成自己的 `error code: 502`。
  要用响应体当信号，就用 **4xx**（CF 不改写 4xx body），或者干脆只用状态码。
- **服务端 502 被当「服务器错误」甩给用户**：一旦识别失败，`speak()` 会抛
  `TTSException('Edge TTS request failed: <Dio 原文>')`，UI 会打出整段 Dio 文案
  （连 Mozilla 文档链接都出来），比原 bug 更难看。→ 判定逻辑要覆盖 service 的**所有公开方法**。
- **`ResponseType.bytes` 下 `e.response.data` 是 `Uint8List`（`_Uint8ArrayView`）**，
  不是 `Map`；要嗅 JSON 必须先 `utf8.decode`。而且**体本身可能已被代理替换**。
- **不要在 `speak()` 里往 broadcast stream 注入假的 `PlayerState.completed`**：见 §3.3，会被丢弃。
- **生产机有未提交改动时**：别 `git reset --hard`；用
  `git checkout -- <file>` → `git fetch my` → `git merge --ff-only my/all-features-combine`。
- **重启 `lute` 后要等 ~10 秒**再判断是否起来了，否则会误以为部署搞挂了生产。
- **`/tmp/sshx/` 是临时 key**：接手第一步先验证 SSH 可达。
- **构建会在两种「环境陈旧」下失败，都不是代码问题**（本轮各踩一次）：
  1. `PathNotFoundException: …/.dart_tool/flutter_build/<hash>/recorded_uses.json`
     —— 先跑过 `flutter analyze` / `flutter test` 之后再 build，`flutter_build` 的 hash 目录会不一致。
     修：`flutter clean` + `rm -rf .dart_tool/flutter_build` + `flutter pub get` 再编。
  2. `:app_settings:compileReleaseKotlin FAILED` / `IllegalStateException: Storage for […/kotlin/…/proto.tab] is already registered`
     —— 上一次**失败**的构建会留下 `GradleDaemon`（实测 **893 MB** RSS）和 `KotlinCompileDaemon`（**584 MB**）。
     这台机器只有 3.9 GB 内存，这些残留既吃内存又让 Kotlin 增量缓存的注册状态变脏。
     修：先按 PID 杀掉残留进程，再 `rm -rf build android/.gradle android/app/build .dart_tool/flutter_build`。
     排查/清理**不要用 `pkill -f <模式>`**：你自己的命令行里就含那个字符串，会**把自己的 SSH 会话一起杀掉**
     （本轮实测就是这样丢掉了一次清理）。用括号技巧取 PID 再 `kill`：
     ```bash
     PIDS=$(ps -eo pid,rss,cmd | grep -E "[G]radleDaemon|[K]otlinCompileDaemon|[G]radleWrapperMain" | awk '{print $1}')
     [ -n "$PIDS" ] && kill -9 $PIDS
     free -m   # 确认可用内存回到 ~2.8GB 再开编
     ```
     编译前顺手确认没有残留：干净时 `free -m` 的 available 约 **2.8 GB**。

---

## 9. 可沉淀为 Skill 的经验

1. **「跨 CDN/代理的错误信号」通用规则**：不要依赖 5xx 的响应体，改用专用 4xx（或响应头）。
   诊断套路：同一 URL 做「经代理 vs 直连源站」双取，比 status / size / content-type / body 四元组。
2. **Flutter 客户端真机取证不带日志时的三件套**：
   nginx access log（请求时序）+ `sips` 裁剪截屏（UI 状态）+ `strings libapp.so`（证明包里的代码）。
3. **「不可发音碎片」这类可跳过错误**：判定要落在 service 的**单一入口**（`_fetchAudio`），
   并把 status→语义 的映射写成**带测试的静态方法**，否则极易被下一次「顺手简化」改坏
   （`test/tts_synthesis_failure_test.dart` 就是为此存在的）。
