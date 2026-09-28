# 词条编辑器的保存改走 outbox（不再直接 POST）

日期：2026-09-28
构建：`_lute_term-edit-outbox_20260928-1133.apk`
sha1：`d7b958ba82df14f787f58a64266cb099ecf88c45`
设备：BOOX Leaf5C（serial `38120d06`）

## 改了什么

`lib/features/terms/widgets/term_edit_dialog_wrapper.dart` 里的两处保存
（`onSave` / `onUpdate`）原先直接调 `contentService.editTerm(...)`，绕过了 outbox。
`/read/edit_term/<id>` 提交的是**整条词**，而这条链路随时可能断 —— 直接发的话，
失败就是一句 `Failed to update term` 加一条已经丢掉的编辑。用户就是在地铁上用这个 app。

现在走 `queueTermFormEdit(outbox, form)`（同文件，`@visibleForTesting` 提出来是为了能测）：

* 有 `termId` → `enqueueTermStatus(termId, status, langId, formData: toFormData())`；
* 没有 `termId`（新词）→ `enqueueTermCreate(...)`，而不是原来的 `termId!` 直接崩。

outbox 本来就是为这个设计的 —— `TermEditIntent` 的注释写着「covers both the double-tap
status cycle and a full save from the term editor」，`coalesce` 里还专门有一条
「后一次裸 status 不能把前一次的表单快照顶掉」。缺的只是接线。

## 单测（`test/term_edit_outbox_wiring_test.dart`，3 例）

用 `ProviderContainer` + `InMemoryOutboxStore`，不需要 widget 树。假 `ContentService`
的 `noSuchMethod` 直接抛 —— 既是占位，也是断言：入队不该有网络副作用。

| 用例 | 断言 |
|---|---|
| 表单编辑进 outbox | 一条 `TermEditIntent`，`termId`/`status`/`langId` 正确，**`formData` 非空且含 `text`/`translation`** |
| 没有 id 的词 | 走 `TermCreateIntent`，不是 `termId!` 崩 |
| 先改表单再双击 | 合并成一条，`status` 取最后一次，**表单快照还在** |

> 坑：`TermForm.toFormData()` 用的键是 `text`，不是 `term`。
> `outbox_service_test.dart` 里手写的 `{'term': '猫'}` 是合成数据，别照着抄。

## 真机验证（11:43–11:46）

编辑 `おっかんか`（termId 12888），状态 1 → 2 → 1，**净改动为零**：

| 时刻 | 事件 |
|---|---|
| 11:43:43 | `GET /read/edit_term/12888 200 12646` — 编辑器打开时拉表单 |
| 11:44:24 | 点状态 **2** |
| **11:44:29** | **`POST /read/edit_term/12888 200 435`** — outbox 冲刷落地（5 秒） |
| 11:44:30–31 | `GET /read/277/page/1` + `refresh_page` — 同步成功后阅读页缓存失效重取 |
| 11:45:33 | 点状态 **1** 还原 |
| **11:45:59** | **`POST /read/edit_term/12888 200 435`** — 还原也落地 |
| 收尾 | 界面标签回到 `Learning 1`，tile 1 选中（`04_*.png`） |

也就是说：**新的入队路径确实能把词条编辑送到服务端**，在线保存没有被改坏。

## 顺带发现：冷启动有一波请求拿不到 session cookie（未修，另一个问题）

第一次尝试验证时，Terms 页显示 "No terms found"。查 nginx 发现冷启动后那一波请求
全被 302 掉了：

```
11:34:02  GET  /info                                  200 123
11:34:03  POST /term/datatables                       302 199   <- 无 cookie，被重定向到 /login
11:34:04  POST /term/datatables                       302 199
11:34:05  GET  /stats/data                            302 233
11:34:06  GET  /language/index                        302 241
11:34:08  GET  /language/edit/13                      302 245
11:34:09  POST /settings/set/stats_calc_sample_size/5 200 36    <- cookie 就绪了
11:34:10  POST /book/datatables/active                200 49483
```

App 把 302 的空响应当成「没有词条」，于是屏幕显示 "No terms found" —— 而服务器上
其实有词条（在搜索框敲一个字符重取：`POST /term/datatables 200 5827`，列表立刻出来）。

**这是长期存在的，不是本轮引入的**：今天 01/02/08/09/10/11 点各有若干 302，
昨天日志里也有，路径都是同一批（`/term/datatables`、`/language/edit/13`、
`/stats/data`、`/settings/set/...`、`/read/termform/...`、`/read/termpopup/...`）。
今天 `/term/datatables` 共 32 次，28 次 200、4 次 302。

对「地铁里打开 app」这个场景来说这值得单独修一轮：冷启动正是用户打开 app 的时刻，
而落在这几百毫秒里的屏（词条、统计、语言）会静默地显示成空的。

## 数字

- `flutter analyze` → **194 issues = 基线逐项一致，0 error**。
- 全量 **39/39 文件通过**（38 → 39，新增 `term_edit_outbox_wiring_test`）。
- 服务器静态目录只剩两个包：11:06 那个（上一轮）与本轮这个。

## 仍未做

* 上一条遗留的窄边界：从没在线看过归档列表 → 断网切过去 → 再联网，归档标签会停在
  "No books found."（归档缓存非空时不受影响）。
* `termsProvider` 没有离线缓存，`loadTerms` 的 catch 是
  `errorMessage: e.toString()` —— 和书架修之前一模一样的毛病（原始 `DioException`
  直接拍给用户）。词条屏离线可用是「地铁里改词义」的前提。
* 冷启动的 302 波（上面那一节）。
