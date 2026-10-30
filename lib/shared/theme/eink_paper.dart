/// 墨水屏「纸张」：最白底 + 最黑正文 + 浅彩状态词块。
///
/// 一份 CSS，三处消费：
///  * `EpubChapterView`（reader-mode EPUB，服务器渲染的章节页）
///  * `LocalBookReaderScreen`（本地导入的 EPUB，App 自己拼的页面）
///  * 将来任何 WebView 正文页
///
/// 为什么不只靠服务器主题：`current_theme` 是**账号级**设置，手机上想读
/// 深色、墨水屏上想读白纸，两者共用一个值就必然互相打脸。把纸色钉在页面
/// 上，墨水屏模式自己说了算。
///
/// 三处关键取值（都是 2026-10-30 真机踩出来的）：
///
///  * `--paper-filter: none` —— styles.css 的 `epub-look-original` 写的是
///    `filter: var(--paper-filter, none)`。服务器主题若是深色，这个变量是
///    `invert(0.88) hue-rotate(180deg)`，于是白纸被反相成黑纸、浅彩词块被
///    反相成暗红暗绿——用户看到的「黑成一团」。钉成 none 才真正白。
///  * 正文 `#000000` 只打在**块级容器**上（p/div/li/td/h1-h6…）。带状态
///    class 的 span 有自己的 color 声明，继承永远输给声明，词块颜色因此
///    保住；而书自带的灰墨（『悪意』原书正文是 #646464）被这一层压成纯黑。
///  * 状态色与 App 端 `eink.dart` 的浅彩方案逐值一致，一处改另一处要跟着
///    改：`status1 #f5d0d0/#7c1d1d`、`status2 #f5e6b8/#6b5a00`、
///    `status3 #cde8cd/#1a5c1a`、`status4 #cdddf5/#1a3d8b`、
///    `status5 #e2d0f5/#4a1a8b`、`status0` 无底 `#1a4f8b` 粗体。
library;

const String eInkPaperCss = '''
:root, body {
  --paper-bg: #ffffff;
  --paper-filter: none;
  --background-color: #ffffff;
  --font-color: #000000;
}
html, body, div#thetext, div#thetext #epub-chapter, div#thetext .epub-body {
  background-color: #ffffff !important;
}
body, div#thetext, div#thetext .epub-body, body .epub-body {
  color: #000000 !important;
}
div#thetext .epub-body div, div#thetext .epub-body p, div#thetext .epub-body li,
div#thetext .epub-body td, div#thetext .epub-body th, div#thetext .epub-body dt,
div#thetext .epub-body dd, div#thetext .epub-body blockquote,
div#thetext .epub-body figcaption, div#thetext .epub-body h1,
div#thetext .epub-body h2, div#thetext .epub-body h3, div#thetext .epub-body h4,
div#thetext .epub-body h5, div#thetext .epub-body h6,
body .epub-body div, body .epub-body p, body .epub-body li, body .epub-body td,
body .epub-body th, body .epub-body dt, body .epub-body dd,
body .epub-body blockquote, body .epub-body figcaption, body .epub-body h1,
body .epub-body h2, body .epub-body h3, body .epub-body h4, body .epub-body h5,
body .epub-body h6 {
  background-color: transparent !important;
  color: #000000 !important;
}
div#thetext .epub-body rt, body .epub-body rt {
  color: #333333 !important;
}
/* 章末导航块是 App 注入的 chrome（"END OF CHAPTER / Prev / Next /
   Contents"），样式在 styles.css 里用的是弱化的灰。墨水屏上弱化等于看不清，
   而且它是翻页的主要入口，一并压黑。
   注意那个块自带一份 `<style>`，规则也带 `!important` 且在本样式之后注入：
   平级特异性会输给它，所以这里用 `body` 前缀抬一级（0,2,1 > 0,1,0）。 */
body .lute-chapter-nav,
body .lute-chapter-nav * {
  color: #000000 !important;
}
span.status0 {
  background-color: transparent !important;
  color: #1a4f8b !important;
  font-weight: 600;
}
span.status1 { background-color: #f5d0d0 !important; color: #7c1d1d !important; }
span.status2 { background-color: #f5e6b8 !important; color: #6b5a00 !important; }
span.status3 { background-color: #cde8cd !important; color: #1a5c1a !important; }
span.status4 { background-color: #cdddf5 !important; color: #1a3d8b !important; }
span.status5 { background-color: #e2d0f5 !important; color: #4a1a8b !important; }
span.status98 {
  background-color: transparent !important;
  color: #444444 !important;
  text-decoration: line-through;
}
span.status99 {
  background-color: transparent !important;
  color: #000000 !important;
}
''';

/// 把 [eInkPaperCss] 装上/卸下的页面脚本。
///
/// `enabled == false`（夜间外观）时整块移除：夜间靠页面的反相滤镜变暗，
/// 把纸色钉成白色等于把夜间模式钉死。
String eInkPaperScript({required bool enabled}) {
  final css = _jsString(eInkPaperCss);
  if (!enabled) {
    return '''
(function () {
  var s = document.getElementById('lute-eink-paper');
  if (s && s.parentNode) s.parentNode.removeChild(s);
  return 'off';
})();''';
  }
  return '''
(function () {
  var s = document.getElementById('lute-eink-paper');
  if (!s) {
    s = document.createElement('style');
    s.id = 'lute-eink-paper';
  }
  s.textContent = $css;
  /* 再 appendChild 一次：已存在的节点会被*移*到 head 末尾，于是纸张样式
     永远排在后来注入的样式（章末块那种自带 <style> 的）之后。 */
  (document.head || document.documentElement).appendChild(s);
  return 'on';
})();''';
}

/// 单引号安全（CSS 里没有单引号，但转义一遍不吃亏）。
String _jsString(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
