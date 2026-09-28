# 书架断网后的错误页卡死 + Retry 无响应（2026-09-28）

设备：Leaf5C（serial `38120d06`），1:1 物理像素截图 1264×1680。
包：`_lute_shelf-offline-recover_20260928-1013.apk`（34,921,487 B，
sha1 `4758e07a7893a07ce2185977c98bb72cfe6f4bd8`）。

## 用户报告

> 我现在打开了wifi，你看我屏幕上，还是error，retry也点不动

屏幕上是书架（不是书集详情页），错误原文：

```
Error
DioException [connection error]: null
Error: Offline: request expired after 30s in the queue
[Retry]
```

## 根因：`copyWith` 把 `null` 吞掉了（不是网络问题）

`BooksState.copyWith` 里：

```dart
errorMessage: errorMessage ?? this.errorMessage,   // 旧写法
```

`errorMessage` 是 `String?` 且没有 `_unset` 哨兵，于是「传 `null` 表示清空」和「没传」
是同一件事 —— 全文件 13 处 `copyWith(errorMessage: null)` **全是空操作**。
错误页成了单向门：断网 30s 超时写下 `DioException` 之后，**再也清不掉**。

同一个坑在 `selectedTag` / `tagFilteredBooks` 上早就用 `_unset` 修过，`errorMessage` 被漏了。
`AudioPlayerState` / `SentenceTTSState` 有同样的写法，一并修了。

## 定案证据

**关键判据：服务端收到了成功的流量，而界面一个像素没动。**

点 Retry 时的 nginx（`172.71.98.224` 是这台设备）：

```
09:59:11  POST /settings/set/stats_calc_sample_size/5   200 36
09:59:12  POST /book/datatables/active                  200 49483
```

点击前后两张截图的 `ImageChops.difference(...).getbbox()` = **`(152, 32, 167, 55)`**，
只有状态栏时钟变了 —— 即 49KB 书目已经发回客户端，屏幕却完全没反映。

这条判据值得记住：**点了按钮 → 服务端有成功流量 + 界面不变 = UI 状态 bug，不是网络 bug。**
（先把原因猜成「`if (_isLoadingBooks) return;` 吞了 Retry」是**错的**，那个窗口只有超时那几微秒。）

## 修复后的真机表现

| # | 文件 | 场景 | 结果 |
|---|---|---|---|
| 01 | `01_shelf_offline_cached_books.png` | 断网 + 有缓存，下拉刷新 | 书目照常显示，**没有**被错误页盖住；顶栏出现警告三角（可达性标志已置假） |
| 02 | `02_shelf_offline_empty_state.png` | 断网 + 该标签无缓存 | 渲染 **Offline 页**（云朵图标 + 说明 + Retry），不再是 DioException |
| 03 | `03_shelf_recovered_online.png` | 恢复 Wi-Fi，**不做任何操作** | 警告三角消失，书目自己回来了 |

自动恢复的 nginx 证据（`10:20`）：

```
10:20:04  GET  /info                                   200 123    ← 队列探针发现链路恢复
10:20:05  POST /settings/set/stats_calc_sample_size/5   200 36     ← 监听器触发 loadBooks
10:20:06  POST /book/datatables/active                  200 49483  ← 书目重新取回
```

另外验证：断网状态下点 Retry **瞬间返回**（不发请求、不挂 30s），
页面与点击前 `diff` 只有时钟 —— 不再是「点了没反应」。

## 复现 02 的步骤（有个坑）

`RefreshIndicator` **在列表为空时无法触发**（`books.isEmpty` 时 body 是 `Center`，
没有可滚动子树）。所以要走：先有非空列表 → 断网下拉刷新 → 再切到空标签。

02 是**等满 30s 队列上限之后**拍的 —— 它同时证明了超时最终落在 Offline 页，
而不是把 `DioException` 原文拍在屏幕上。

## 遗留（未修，非本次报告的问题）

**第一次**断网请求仍要等满 30s 才进 Offline 态。原因：`ServerStatusManager.isReachable`
在「第一次失败之前」还是 `true`（刚断网时没有任何请求失败过，队列也不会主动探测），
所以 `loadBooks` 的可达性短路拦不住这一次，请求被扣进队列等到 30s 上限。
这 30s 里空标签显示的是「No books found. / Add books in Song server first.」—— 文案是错的
（见 02 拍之前的中间态）。

修法方向（需要单独一轮，因为 `setUserSetting` 也被设置页共用）：给书架列表这条读路径
加 `noQueue`（和页内容同样的处理 —— 用户在等、且有缓存可退），让它在不可达时立刻失败；
或引入 `connectivity_plus`，在网卡掉线时立刻把可达性标志置假。
