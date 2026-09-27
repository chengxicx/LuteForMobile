# 漫画:适应全屏按钮 + 放大后边界滑动翻页(2026-09-27)

用户反馈(Leaf 5C):
1. 打开漫画「右边被切边」,想「挪动就翻页」;
2. 漫画顶栏希望加一个「适应全屏」按钮。

## 诊断结论

**右边缘"切边"不是 app 裁的,是源扫描图本身没有右边距。**
像素级对齐验证:原图 010.jpg(1080×1530)的左框线 x=78 映射到截图 x=92,
反推显示缩放恰好 = 1264/1080、起点 x≈0 —— app 完整显示了整张图。
该书的扫描件左侧有 69px 白边、右侧内容(连气泡描边、速度线)直接顶到文件右缘,
顶部/底部同样贴边;mokuro OCR 框与声明尺寸自洽。切边发生在 CBZ 源文件里。
app 层无法补回缺失的纸边;若要修,需在导入前给源图补白(见文末"可选后续")。

**「挪动就翻页」失效的真因**:放大(scale > 1.01)时,滑动只平移、永不翻页
(`_onPointerUp` 里 `scale > 1.01` 直接 return)。用户正是放大阅读的状态。
另外 1x 下横向快滑翻页本身正常。

## 改动

### `lib/features/reader/widgets/manga_page_view.dart`
- 新增 `fitToScreen` 属性:
  - false(默认,fit-width):页宽铺满视口、纵向平移(原行为);
  - true(fit-screen):整页 contain 缩放进视口、居中留白(对齐 web 端
    lute.js `_fitMangaPage` 的默认拟合)。视口尺寸的 child 内居中放页,
    两个模式下 InteractiveViewer 的 child 都 ≥ 视口,平移钳制保持良定义。
  - 切换模式时变换矩阵重置为单位阵。
- 放大状态下改为 Tachiyomi 式边界翻页:按下那一刻的平移偏移已在横向边界、
  且快滑方向朝界外,才翻页;否则快滑 = 平移。判定用 `_txAtDown`
  (按下时的 tx),不能用松手时的 —— 快滑自身会把画面平移到边界再松手。
- 顺带修了一个既有隐患:双指捏合的位移(±120px)满足快滑阈值,1x 下
  捏合松手会误翻页。现在多指手势不参与快滑判定(计数 + 取消事件兜底)。

### `lib/features/reader/widgets/reader_screen.dart`
- `_mangaFitToScreen` 状态(跨页保持,重启复位,同 `_mangaRevealAll`);
- 两处 AppBar(全屏/普通)在眼睛图标旁各加一个按钮:
  `Icons.fullscreen`(关)↔ `Icons.fit_screen`(开),
  tooltip 'Fit page to screen' / 'Fit page to width'。

### `test/manga_vertical_render_test.dart`
新增两个用例(共 13 个全绿):
- 适应全屏:整页缩放进视口、水平居中留白,不再裁边(含 fit-width 对照);
- 放大状态:边界外快滑不翻页、平移到右边界后左滑翻下一页、
  回到左边界右滑翻上一页。

## 验证

- 服务器 `flutter analyze` 0 error(194 条 info/warning 均为存量);
- 全部 23 个测试文件逐文件跑,全绿;
- 装机实测:`flutter` 无,sendevent 注入双指被 SELinux 拦
  (`u:r:shell:s0` 无 /dev/input 写权限),放大态真机手测做不了,
  该路径由 widget 测试覆盖。
- 真机已验证:适应全屏整页可见 + 图标切换、1x 滑动翻页(10→11)、
  fit-screen 跨页保持。

## APK

`dist/_lute_manga_fitscreen_20260927-134646.apk`
CDN:`https://www.metaman.dpdns.org/static/_lute_manga_fitscreen_20260927-134646.apk`
sha1 `c160452e3efd736c59a2dc2d195d034a74920a3d`(与服务器侧一致)。
服务器 `/opt/lute/lute/static/` 上的同名文件留待用户确认后清理。

## 可选后续(未做)

- 源图补白:这本书的扫描全部缺右/上/下边距,可写脚本给每页右侧对称补白
  后重导入,mokuro 框坐标是像素制、右补白不影响已有框,但 img_width 与
  数据库 manga JSON 需同步改,建议走重导入流程。
- fit-screen 偏好若需要跨重启持久化,可加到排版设置模型(现与会话同寿命)。
