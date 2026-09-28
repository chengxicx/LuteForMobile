# 书架断网：从「等 30 秒」改成「秒进 Offline」

日期：2026-09-28
构建：`_lute_offline-fastfail_20260928-1106.apk`
sha1：`e452b52251ce4014c5684f175b4c84b98a273d17`
设备：BOOX Leaf5C（serial `38120d06`，物理 1264×1680）

## 要证的那件事

上一轮修好了「书架断网后卡在错误页、Retry 点不动」，但**第一次**断网请求仍然要
在 `ApiRequestQueue` 里挂满 `requestDeadline`（30 秒）才承认离线 —— 用户先干等
半分钟才看到 Offline。

这一轮把书架的列表读路径改成不排队（`noQueue`）：`getActiveBooks`、
`getArchivedBooks`，以及紧挨在它们前面的 `setUserSetting`（每次加载都会重发的
提示，排队重放毫无意义，却会把后面那个读请求一起拖到 30 秒上限）。

`noQueue` 的语义是「别排队，现在就失败」；`bypassQueue`（离线 outbox 用）是
「别排队、也别告诉我服务器挂了」。两者都在 `ApiService` 里，不要混。

## 时间线（设备侧实测）

| 时刻 | 动作 | 结果 |
|---|---|---|
| 11:08:44–45 | 在线打开书架 | `POST /settings/set/...` + `GET /settings/index` + `POST /book/datatables/active 200 49483` |
| 11:09:04 | `svc wifi disable` | `cmd wifi status` → `Wifi is disabled` |
| 11:09:07 | 点 "Active Only" 切到归档列表 | 标签翻成 "Show Archived" |
| 11:09:07+0.3s | 第 1 帧截图 | **已经是 Offline 页**（云朵断线图标 + Retry），不是 `DioException` 原文 |
| 11:09:15 | 第 30 帧截图 | 与第 1 帧**逐像素完全相同** —— 0.3 秒内就稳定了，之后没有任何变化 |

服务器侧同一窗口（`/var/log/nginx/access.log`，服务器本地时间与 Mac 一致）：

```
--- last 3 requests BEFORE 11:09 ---
162.159.113.159 [28/Sep/2026:11:08:44] "POST /settings/set/stats_calc_sample_size/5" 200 36
172.70.214.2    [28/Sep/2026:11:08:44] "GET /settings/index" 200 22206
162.159.113.159 [28/Sep/2026:11:08:45] "POST /book/datatables/active" 200 49483
--- ALL requests 11:09:00-11:10:00 ---
0
```

**11:09 这一分钟服务器一条请求都没收到**，而屏幕在 0.3 秒内就落到了 Offline。
两条合起来说明：失败完全发生在本地，没有半分钟的等待。

> 坑：第一次查日志用 `grep -E ':09:0[4-9]'` 命中了 `02:09:08`（子串 `:09:08`），
> 差点得出「请求成功打到了服务器」的反结论。按完整日期前缀
> `28/Sep/2026:11:09:` 重新统计才是 0。

## 自愈仍然有效

11:10:45 `svc wifi enable`，之后**不做任何用户操作**：

```
104.23.251.125 [11:10:53] "GET /info" 200 123                    <- 队列探针，唯一会把可达性置回 true 的地方
104.22.109.48  [11:10:54] "POST /settings/set/stats_calc_sample_size/5" 200 36
104.22.109.10  [11:10:55] "POST /book/datatables/active" 200 49483
```

标题栏那个红色警告三角消失了，书架自己重载了（`04_...png`）。

## 机制用单测钉死

设备只能证明「结果快」，证明不了「是哪条路快」。`test/offline_fast_fail_test.dart`
（2 个用例，`requestDeadline` 放到 30 秒，所以「排队」不可能在 2 秒内抛错）：

* 带 `noQueue` 的请求：日志里**没有** `[enqueue]` 行，`queueLength == 0`，
  立刻抛 `DioException`；
* 不带 `noQueue` 的请求：`[enqueue] ... queueLength=1` → 到点才
  `expired after 0s in the queue`。

## 顺带查清、但不是 bug 的两件事

1. **归档列表的 "No books found." 是真话。** 自愈重载取的是 active 列表
   （`loadBooks` 只走 `_loadBooksFromNetwork`），屏幕停在 Archived 标签时看起来
   像是没刷新。实测在线切一次归档：`POST /book/datatables/Archived 200 49` ——
   49 字节的空结果，服务器上确实没有归档书。

2. **`settings get global wifi_on` 不能信。** 这台机器上 Wi-Fi 明明连着它也可能
   报 `0`；用 `cmd wifi status`。

## 遗留（本轮没动）

* **窄边界**：从没在线看过归档列表、断网时切到归档、再联网 —— 自愈只重载 active，
  归档标签会停在 "No books found."。归档缓存非空时不受影响（`loadBooks` 会从缓存
  恢复）。用户当前没有归档书，所以没触发。
* **可达性标志的陈旧窗口**：Wi-Fi 刚断、还没有任何请求失败的那几百毫秒里
  `ServerStatusManager.isReachable` 仍是 true。`noQueue` 把这段时间从 30 秒压到
  毫秒级，但严格讲还是「先失败一次才知道离线」。
* `term_edit_dialog_wrapper.dart` 直接调 `contentService.editTerm`，绕过了 outbox，
  离线改词义仍可能丢。
