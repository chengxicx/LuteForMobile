Dart/Flutter project
Ignore the lute-v3 directory

## Build & delivery 流程（固定，勿改道）

### 服务器上有两套 Flutter + 两份项目树，别串了（2026-09-26 实测更正）

| | 验证树 | 发布构建树 |
|---|---|---|
| Flutter | `/root/android-dev/flutter/bin` | `/opt/flutter` |
| 项目 | `/root/android-dev/src/LuteForMobile` | `/opt/lute_mobile_src` |
| 用途 | `analyze` / `test`，秒级反馈 | 出 release APK（`/opt/build_apk.sh` 里 `cd /opt/lute_mobile_src`） |

**两份树不共享代码**：只同步验证树就出包，包里还是发布树的旧代码。改动要同步到**两边**。

### 1. 同步改动（增量，秒级）

```bash
rsync -az --delete -e "ssh -o BatchMode=yes" lib/  root@172.236.226.132:/root/android-dev/src/LuteForMobile/lib/
rsync -az --delete -e "ssh -o BatchMode=yes" test/ root@172.236.226.132:/root/android-dev/src/LuteForMobile/test/
```

出包前同样把 `lib/` 同步到 `/opt/lute_mobile_src/`。`--delete` 必须带，否则远端删掉的文件会留下并参与编译。

### 2. 验证

```bash
ssh root@172.236.226.132 'cd /root/android-dev/src/LuteForMobile && export PATH=/root/android-dev/flutter/bin:$PATH && flutter analyze'
```

- `flutter analyze` 只要有任何 issue 就非零退出，**按严重级别判断**，只有 `error` 是致命的。
- `flutter test` **逐文件跑**（`for f in test/*_test.dart; do timeout 90 flutter test "$f"; done`），整目录并发在这台 3.8GB 的机器上会挂住十分钟不出声。

### 3. 构建 release APK

`/opt/build_apk.sh` 从 `/opt/lute_mobile_src` 构建，**必须包在 cgroup 里**，否则默认 `-Xmx8G` 会把整台机器（含同机的 lute / nginx / mariadb）压进 swap：

```bash
ssh root@172.236.226.132 'systemctl reset-failed fbuild.service 2>/dev/null;
  systemd-run --collect --unit=fbuild -p MemoryMax=2400M -p MemorySwapMax=3G --setenv=HOME=/root \
    bash -c "bash /opt/build_apk.sh > /tmp/build.log 2>&1; echo EXIT=\$? >> /tmp/build.log"'
# 轮询：grep EXIT= /tmp/build.log；systemctl is-active fbuild.service
```

产物：`/opt/lute_mobile_src/build/app/outputs/flutter-apk/app-release.apk`（约 28MB，arm64 only，sha1 在同目录 `.sha1`）。
缓存命中约 2 分钟；`systemd-run --wait` 不能用（与 `--scope` 互斥，去掉 `--scope` 又变成"启动即返回"，会在没构建的情况下报 success）。

### 4. APK 交付走 CDN，不要用 rsync/scp 拉回

服务器上行只有几十 KB/s，rsync 要 20+ 分钟：

1. 拷进 nginx 静态目录：`cp <apk> /opt/lute/lute/static/_lute_<描述>_<时间戳>.apk`
2. CDN 下载：`curl -sL -o dist/<名字>.apk "https://www.metaman.dpdns.org/static/<文件名>"`
   （实测 33 秒 ~ 3 分钟，波动大；用 `shasum -a 1` 与服务器侧 `sha1sum` 校验）
3. 用户手机直接下载也用同一个 CDN URL，所以下载完先别删服务器上的文件，等用户确认后再清理。
4. 文件名**必须带时间戳**：CDN 按 URL 缓存，同名新包会拿到旧字节（HTTP 200、体积相同，只有 sha256 能看出来）。

### 5. 装机验证（设备常插着 USB）

```bash
ADB=~/.workbuddy-ai/binaries/platform-tools/platform-tools/adb
$ADB devices -l                      # Leaf5C 的 serial 是 38120d06
$ADB -s 38120d06 install -r dist/<名字>.apk     # BOOX 没有 ColorOS 的 -99 拦截，直接成功
```

- 截图是**物理像素**（Leaf5C 上 1264×1680），`input tap` 也用物理像素，一一对应。
- 取证用 `/usr/bin/python3` + PIL 从截图**量像素**，不要凭预览图估坐标（预览是缩放过的）。
- 测完还原：`svc power stayon false`、`settings put system screen_off_timeout 60000`。
- 静态目录里已下载完的 `_lute_*.apk` 遗留文件要及时删除（详见
  `docs/handoff-2026-09-24.md` 的 "Getting the APK back to local" 一节）。
