import 'dart:convert';

/// 词卡「Sentence」面板断网时用的本地网页模板。
///
/// 在线时这一页是 WebView 直接渲染服务端的 `ai/sentence.html`；断网时没有
/// 服务器可请求，但**不必改成另一套 Flutter 排版**——这里把服务端那一页的
/// 样式、DOM 骨架和 `renderResult()` 系列渲染函数原样搬过来，只是把数据来源
/// 从 `/ai/translate` 的 SSE 换成本地缓存里的 JSON。于是原文框、译文、
/// Word-by-word 三列表格、Grammar points / Context / Examples、字号行距、
/// 以及 App 注入的主题配色都与联网时一致。
///
/// 样式来源：lute-v3 `lute/templates/ai/sentence.html` 的内联 `<style>` +
/// `lute/static/css/styles.css` 的 body / .btn 基础规则。服务端改了那页的
/// 样式时要同步这里（类名和结构保持一致，复制粘贴即可）。TTS 按钮、句子
/// 前后翻页箭头等离线用不到的元素与动画没有搬，它们不参与排版。
const String _pageStyle = r'''
* { margin: 0; padding: 0; }
body {
  --font-color: #000;
  --background-color: #fff;
  --btn-accent: #007aff;
  background-color: var(--background-color);
  color: var(--font-color);
  font: 100%/1.25 "Lucida Grande", Arial, sans-serif, STHeiti, "Arial Unicode MS", MingLiu;
  margin: 0;
  padding: 1.1rem 1.4rem 1.4rem;
}
.ai-card { max-width: 46rem; }
.ai-card [hidden] { display: none; }
.ai-eyebrow {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.72rem;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: color-mix(in srgb, var(--font-color, #888) 55%, transparent);
  margin: 0 0 0.35rem 0;
}
.ai-badge {
  display: inline-block;
  margin-left: auto;
  padding: 0.05rem 0.4rem;
  border-radius: 999px;
  font-size: 0.68rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: color-mix(in srgb, var(--btn-accent, #2f6fdb) 85%, var(--font-color, #333));
  background: color-mix(in srgb, var(--btn-accent, #2f6fdb) 14%, transparent);
}
.ai-source {
  margin: 0 0 0.9rem 0;
  padding: 0.65rem 0.85rem;
  border-left: 3px solid color-mix(in srgb, var(--font-color, #888) 30%, transparent);
  border-radius: 0.25rem;
  background: color-mix(in srgb, var(--font-color, #888) 6%, transparent);
  font-size: 0.95rem;
  line-height: 1.45;
  overflow-wrap: anywhere;
}
.ai-result {
  font-size: 1.05rem;
  line-height: 1.55;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  min-height: 1.5rem;
}
.ai-sections { margin-top: 1.1rem; }
.ai-section { margin-top: 1.1rem; }
.ai-section:first-child { margin-top: 0; }
.ai-section-title {
  margin: 0 0 0.4rem 0;
  font-size: 0.8rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  color: color-mix(in srgb, var(--font-color, #888) 65%, transparent);
}
.ai-table { width: 100%; border-collapse: collapse; font-size: 0.9rem; line-height: 1.4; }
.ai-table th, .ai-table td {
  padding: 0.3rem 0.45rem;
  text-align: left;
  vertical-align: top;
  border-bottom: 1px solid color-mix(in srgb, var(--font-color, #888) 14%, transparent);
  overflow-wrap: anywhere;
}
.ai-table th {
  font-size: 0.75rem;
  font-weight: 600;
  color: color-mix(in srgb, var(--font-color, #888) 60%, transparent);
}
.ai-table td:first-child { font-weight: 600; }
.ai-reading {
  display: block;
  font-size: 0.76rem;
  font-weight: 400;
  color: color-mix(in srgb, var(--font-color, #888) 65%, transparent);
}
.ai-grammar-item { margin: 0 0 0.55rem 0; font-size: 0.92rem; line-height: 1.45; }
.ai-grammar-item:last-child { margin-bottom: 0; }
.ai-fragment {
  display: inline-block;
  margin-left: 0.35rem;
  padding: 0 0.3rem;
  border-radius: 0.2rem;
  background: color-mix(in srgb, var(--font-color, #888) 10%, transparent);
  font-size: 0.82rem;
  font-weight: 400;
}
.ai-context, .ai-example { font-size: 0.92rem; line-height: 1.5; overflow-wrap: anywhere; }
.ai-context { margin: 0; white-space: pre-wrap; }
.ai-examples { margin: 0; padding-left: 1.2rem; }
.ai-examples li { margin-bottom: 0.45rem; }
.ai-examples li:last-child { margin-bottom: 0; }
.ai-example-translation {
  display: block;
  color: color-mix(in srgb, var(--font-color, #888) 75%, transparent);
}
.ai-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.6rem;
  margin-top: 1rem;
  font-size: 0.85rem;
}
.ai-action-group { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
.ai-state {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 0.5rem 0;
  font-size: 0.85rem;
  line-height: 1.4;
  color: color-mix(in srgb, var(--font-color, #888) 70%, transparent);
}
a.btn, button.btn, .btn-secondary {
  display: inline-block;
  font-family: inherit;
  font-size: 0.85rem;
  font-weight: 600;
  line-height: 1.35;
  padding: 0.32rem 1.2rem;
  border: 1px solid var(--btn-accent);
  border-radius: 980px;
  background: var(--btn-accent);
  color: #fff;
  cursor: pointer;
  white-space: nowrap;
  text-decoration: none;
}
button.btn-secondary { background: transparent; color: var(--btn-accent); }
''';

/// 服务端 `sentence.html` 的 `renderResult()` 系列，去掉了 TTS 与 SSE 部分。
/// 数据从 `DATA` 读，所有文本都走 `textContent`，页面里不拼接任何动态 HTML。
const String _pageScript = r'''
(function () {
  var L = DATA.labels;
  var resultEl = document.getElementById('ai-result');
  var sectionsEl = document.getElementById('ai-sections');

  function section(title) {
    var box = document.createElement('div');
    box.className = 'ai-section';
    if (title) {
      var h = document.createElement('h2');
      h.className = 'ai-section-title';
      h.textContent = title;
      box.appendChild(h);
    }
    sectionsEl.appendChild(box);
    return box;
  }

  function textOf(value) {
    return typeof value === 'string' ? value.trim() : '';
  }

  function renderSegments(segments) {
    if (!segments.length) return;
    var box = section(L.segments);
    var table = document.createElement('table');
    table.className = 'ai-table';
    var head = document.createElement('thead');
    var headRow = document.createElement('tr');
    [L.part, L.meaning, L.role].forEach(function (label) {
      var th = document.createElement('th');
      th.textContent = label;
      headRow.appendChild(th);
    });
    head.appendChild(headRow);
    table.appendChild(head);
    var body = document.createElement('tbody');
    segments.forEach(function (segment) {
      if (!segment || typeof segment !== 'object') return;
      var row = document.createElement('tr');
      var part = textOf(segment.part);
      var reading = textOf(segment.reading);
      var partCell = document.createElement('td');
      partCell.textContent = part;
      if (reading && reading !== part) {
        var readingEl = document.createElement('span');
        readingEl.className = 'ai-reading';
        readingEl.textContent = reading;
        partCell.appendChild(readingEl);
      }
      row.appendChild(partCell);
      [textOf(segment.meaning), textOf(segment.role)].forEach(function (value) {
        var td = document.createElement('td');
        td.textContent = value;
        row.appendChild(td);
      });
      body.appendChild(row);
    });
    table.appendChild(body);
    box.appendChild(table);
  }

  function renderGrammar(items) {
    if (!items.length) return;
    var box = section(L.grammar);
    items.forEach(function (item) {
      if (!item || typeof item !== 'object') return;
      var point = textOf(item.point);
      var explanation = textOf(item.explanation);
      var fragment = textOf(item.fragment);
      if (!point && !explanation && !fragment) return;
      var row = document.createElement('div');
      row.className = 'ai-grammar-item';
      var strong = document.createElement('strong');
      strong.textContent = point || fragment;
      row.appendChild(strong);
      if (fragment && point) {
        var chip = document.createElement('span');
        chip.className = 'ai-fragment';
        chip.textContent = fragment;
        row.appendChild(chip);
      }
      if (explanation) {
        row.appendChild(document.createTextNode(' — ' + explanation));
      }
      box.appendChild(row);
    });
    if (!box.querySelector('.ai-grammar-item')) box.remove();
  }

  function renderContext(value) {
    if (!value) return;
    var box = section(L.context);
    var p = document.createElement('p');
    p.className = 'ai-context';
    p.textContent = value;
    box.appendChild(p);
  }

  function renderExamples(items) {
    if (!items.length) return;
    var box = section(L.examples);
    var list = document.createElement('ol');
    list.className = 'ai-examples';
    items.forEach(function (item) {
      if (!item || typeof item !== 'object') return;
      var source = textOf(item.source);
      var translation = textOf(item.translation);
      if (!source && !translation) return;
      var li = document.createElement('li');
      var s = document.createElement('span');
      s.className = 'ai-example';
      s.textContent = source;
      li.appendChild(s);
      if (translation) {
        var tr = document.createElement('span');
        tr.className = 'ai-example-translation';
        tr.textContent = translation;
        li.appendChild(tr);
      }
      list.appendChild(li);
    });
    if (!list.children.length) { box.remove(); return; }
    box.appendChild(list);
  }

  function renderResult(result) {
    sectionsEl.textContent = '';
    if (!result || typeof result !== 'object') { resultEl.textContent = ''; return; }
    resultEl.textContent = textOf(result.translation);
    renderSegments(Array.isArray(result.segments) ? result.segments : []);
    renderGrammar(Array.isArray(result.grammar) ? result.grammar : []);
    renderContext(textOf(result.context));
    renderExamples(Array.isArray(result.examples) ? result.examples : []);
  }

  document.getElementById('ai-provider').textContent = DATA.providerLabel;
  var badge = document.getElementById('ai-badge');
  badge.textContent = DATA.badgeLabel;
  // The markup starts with `hidden` (like the server page); a non-empty
  // label has to clear it or Cached / Offline never shows up.
  badge.hidden = !DATA.badgeLabel;
  document.getElementById('ai-source-text').textContent = DATA.sentence;

  if (DATA.result) renderResult(DATA.result);
  else if (DATA.fallbackText) resultEl.textContent = DATA.fallbackText;
  if (!DATA.hasContent) {
    var state = document.createElement('div');
    state.className = 'ai-state';
    state.textContent = DATA.emptyMessage;
    sectionsEl.appendChild(state);
  }

  document.getElementById('ai-retry').addEventListener('click', function () {
    try {
      window.flutter_inappwebview.callHandler('retryOnline');
    } catch (e) {
      // The host is gone (panel closed): nothing to retry.
    }
  });
})();
''';

/// JSON 里可能出现 `</script>`、`&` 或 U+2028 这类会截断/改写 `<script>`
/// 内容的字符。这里转成等价的 JS 转义，浏览器解析后仍是原文。
String _jsonForScript(Object? data) => jsonEncode(data)
    .replaceAll('<', r'\u003C')
    .replaceAll('>', r'\u003E')
    .replaceAll('&', r'\u0026')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// 生成一份完全自包含的离线 HTML：没有任何外链资源、任何网络请求。
String buildOfflineSentenceAiHtml({
  required String sentence,
  required Map<String, dynamic>? result,
  required String? fallbackText,
  required String themeCss,
  required String providerLabel,
  required String badgeLabel,
  required bool hasContent,
  required String emptyMessage,
}) {
  final data = <String, dynamic>{
    'sentence': sentence,
    'result': result,
    'fallbackText': fallbackText,
    'providerLabel': providerLabel,
    'badgeLabel': badgeLabel,
    'hasContent': hasContent,
    'emptyMessage': emptyMessage,
    'labels': <String, String>{
      'segments': 'Word-by-word',
      'part': 'Part',
      'meaning': 'Meaning',
      'role': 'Role',
      'grammar': 'Grammar points',
      'context': 'Context',
      'examples': 'Examples',
    },
  };

  return '<!DOCTYPE html>\n'
      '<html><head><meta charset="utf-8" />\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
      '<style>\n$_pageStyle\n$themeCss\n</style>\n'
      '</head><body>\n'
      '<div class="ai-card">\n'
      '  <div class="ai-eyebrow"><span id="ai-provider"></span>'
      '<span id="ai-badge" class="ai-badge" hidden></span></div>\n'
      '  <div class="ai-source"><span class="ai-source-text" id="ai-source-text"></span></div>\n'
      '  <div id="ai-result" class="ai-result" aria-live="polite"></div>\n'
      '  <div id="ai-sections" class="ai-sections"></div>\n'
      '  <div class="ai-actions"><span class="ai-action-group">'
      '<button type="button" id="ai-retry" class="btn btn-secondary">Retry</button>'
      '</span></div>\n'
      '</div>\n'
      '<script>var DATA = ${_jsonForScript(data)};\n$_pageScript</script>\n'
      '</body></html>';
}
