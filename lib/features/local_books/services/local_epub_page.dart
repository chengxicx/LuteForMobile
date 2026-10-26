import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;

/// Bump when the reading-page template (the CSS/JS below) changes:
/// books imported with an older version get their chapter pages
/// rebuilt from the kept original .epub on first open.
const int localEpubPageVersion = 2;

/// Tags removed entirely -- active content a book never needs (mirrors
/// the server's `epub_extract._DROP_TAGS`, minus link/style which the
/// local mode keeps so the book's own styling loads).
const Set<String> _dropTags = {
  'script',
  'noscript',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'base',
  'form',
  'input',
  'button',
  'textarea',
  'select',
};

/// A chapter's declared fixed-layout viewport, when it has one.
class LocalChapterViewport {
  const LocalChapterViewport(this.width, this.height);
  final int width;
  final int height;
}

/// Result of the page build.
class LocalChapterPage {
  const LocalChapterPage({required this.html, this.viewport});
  final String html;
  final LocalChapterViewport? viewport;
}

/// Parses a pixel viewport meta value (`width=768, height=1024` style).
/// Returns null for reflow layouts (device-width spellings, missing
/// dimensions) -- the same rule the server import applies.
LocalChapterViewport? parseViewportMeta(String? content) {
  if (content == null) return null;
  final pairs = <String, String>{};
  for (final part in content.split(',')) {
    final bits = part.split('=');
    if (bits.length != 2) continue;
    pairs[bits[0].trim().toLowerCase()] = bits[1].trim();
  }
  final w = int.tryParse(pairs['width'] ?? '');
  final h = int.tryParse(pairs['height'] ?? '');
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return LocalChapterViewport(w, h);
}

/// Sanitises [rawXhtml] and wraps it into the standalone local reading
/// page.  Never throws on odd markup: the html parser is tolerant, and
/// anything unparsable degrades to the raw text inside the page body.
LocalChapterPage buildLocalChapterPage(String rawXhtml) {
  var document = html_parser.parse(rawXhtml);
  try {
    _sanitize(document);
  } catch (_) {
    document = html_parser.parse('<html><body></body></html>');
  }

  // The book's own viewport meta was only needed for fixed-layout
  // detection; the reading page always lays out to the device.
  final viewport = _detectViewport(document);
  for (final meta in document.head?.querySelectorAll('meta[name=viewport]') ??
      const <html.Element>[]) {
    meta.remove();
  }

  _injectPageAssets(document);
  _wrapBody(document, viewport);

  return LocalChapterPage(
    html: document.outerHtml,
    viewport: viewport,
  );
}

void _sanitize(html.Document document) {
  // Drop active-content tags.
  for (final tag in _dropTags) {
    for (final el in document.querySelectorAll(tag)) {
      el.remove();
    }
  }

  // Event handler attributes and javascript: URLs.
  const urlAttrs = {'href', 'src', 'poster', 'xlink:href', 'data'};
  for (final el in document.querySelectorAll('*')) {
    final names = el.attributes.keys.map((k) => k.toString()).toList();
    for (final name in names) {
      final local = name.toLowerCase();
      if (local.startsWith('on')) {
        el.attributes.remove(name);
        continue;
      }
      if (urlAttrs.contains(local)) {
        final value = (el.attributes[name] ?? '').toString().trim().toLowerCase();
        if (value.startsWith('javascript:')) {
          el.attributes.remove(name);
        }
      }
    }
  }
}

LocalChapterViewport? _detectViewport(html.Document document) {
  for (final meta in document.querySelectorAll('meta[name=viewport]')) {
    final vp = parseViewportMeta(meta.attributes['content']?.toString());
    if (vp != null) return vp;
  }
  return null;
}

void _wrapBody(html.Document document, LocalChapterViewport? viewport) {
  final body = document.body;
  if (body == null) return;
  final wrapper = document.createElement('div');
  wrapper.classes.add('epub-body');
  if (viewport != null) {
    wrapper.attributes['data-epub-viewport'] = '${viewport.width}x${viewport.height}';
    wrapper.classes.add('epub-fixed');
  }
  while (body.nodes.isNotEmpty) {
    wrapper.append(body.nodes.first);
  }
  body.append(wrapper);
}

void _injectPageAssets(html.Document document) {
  final head = document.head ?? document.createElement('head');
  if (document.head == null) {
    document.documentElement?.nodes.insert(0, head);
  }
  final body = document.body ?? document.createElement('body');
  if (document.body == null) {
    document.documentElement?.append(body);
  }

  final meta = document.createElement('meta');
  meta.attributes['name'] = 'viewport';
  meta.attributes['content'] =
      'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
  head.nodes.insert(0, meta);

  final style = document.createElement('style');
  style.text = _pageCss;
  head.append(style);

  final script = document.createElement('script');
  script.text = _pageJs;
  body.append(script);
}

const String _pageCss = '''
/* Local-book reading page base. The book's own stylesheets (kept in
   the chapter markup) apply on top of this. */
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  padding: 12px 10px 48px;
  font-size: var(--lute-local-font-size, 18px);
  -webkit-user-select: text;
  user-select: text;
}
.epub-body { max-width: 46rem; margin: 0 auto; }
img, video, svg { max-width: 100%; height: auto; }
.epub-body[data-epub-viewport] { max-width: none; margin: 0; }
/* Night mode: invert without touching the media. */
body.local-night {
  background: #16161d;
  filter: invert(0.88) hue-rotate(180deg);
}
body.local-night img, body.local-night video, body.local-night svg {
  filter: invert(1) hue-rotate(180deg);
}
#lute-local-lookup {
  position: absolute;
  display: none;
  z-index: 9999;
  padding: 8px 14px;
  border-radius: 18px;
  background: #2d6cdf;
  color: #fff;
  font-size: 14px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.35);
  cursor: pointer;
  user-select: none;
  -webkit-user-select: none;
}
#lute-local-lookup.show { display: block; }
''';

const String _pageJs = '''
(function () {
  "use strict";
  var NIGHT_KEY = "localEpubNight";
  var FONT_KEY = "localEpubFontSize";

  function callFlutter(name, payload) {
    if (window.flutter_inappwebview &&
        window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(name, payload);
    }
  }

  /* ---- settings (persisted, pushed by the native reader) ---- */

  function applyNight(on) {
    document.body.classList.toggle("local-night", on);
    try { localStorage.setItem(NIGHT_KEY, on ? "1" : "0"); } catch (e) {}
  }
  function applyFontSize(px) {
    px = parseInt(px, 10);
    if (!Number.isFinite(px) || px <= 0) return;
    document.documentElement.style.setProperty("--lute-local-font-size", px + "px");
    try { localStorage.setItem(FONT_KEY, String(px)); } catch (e) {}
  }
  try {
    applyNight(localStorage.getItem(NIGHT_KEY) === "1");
    var savedFont = parseInt(localStorage.getItem(FONT_KEY), 10);
    if (Number.isFinite(savedFont) && savedFont > 0) applyFontSize(savedFont);
  } catch (e) {}

  window.LuteLocalBridge = {
    setNight: applyNight,
    setFontSize: applyFontSize
  };

  /* ---- fixed-layout fit (width, like the server reader) ---- */

  function fitFixed() {
    var page = document.querySelector(".epub-body[data-epub-viewport]");
    if (!page) return;
    var vp = (page.dataset.epubViewport || "").split("x");
    var natW = parseFloat(vp[0]);
    var natH = parseFloat(vp[1]);
    if (!natW || !natH) return;
    var fit = Math.min(1, document.documentElement.clientWidth / natW) || 1;
    page.style.maxWidth = "none";
    page.style.width = Math.max(10, Math.floor(natW * fit)) + "px";
    page.style.height = Math.max(10, Math.floor(natH * fit)) + "px";
    page.style.margin = "0 auto";
  }
  window.addEventListener("resize", fitFixed);
  window.addEventListener("load", fitFixed);

  /* ---- word lookup: long-press selection or tap-to-word, then the
     floating button calls the native dictionary sheet ---- */

  var btn = document.createElement("div");
  btn.id = "lute-local-lookup";
  btn.textContent = "\\u67e5\\u8bcd";
  document.body.appendChild(btn);

  var selTimer = null;
  function selectionText() {
    var s = window.getSelection();
    if (!s || s.rangeCount === 0) return "";
    var t = s.toString().replace(/\\s+/g, " ").trim();
    // Long prose belongs to copy, not lookup.
    return t.length > 80 ? "" : t;
  }
  function hideBtn() { btn.classList.remove("show"); }
  function showBtn(text) {
    var s = window.getSelection();
    if (!s || s.rangeCount === 0) { hideBtn(); return; }
    var r = s.getRangeAt(0).getBoundingClientRect();
    btn.dataset.text = text;
    // Absolute positioning against the document (fixed elements can
    // misbehave in Android WebView while the selection ActionMode is
    // up), and BELOW the selection: the system ActionMode menu sits
    // above it and would cover the button otherwise.
    var left = Math.max(8, Math.min(
      r.left + r.width / 2 - 28 + window.scrollX,
      document.documentElement.clientWidth - 64));
    var below = r.bottom + 12 + window.scrollY;
    var above = r.top - 44 + window.scrollY;
    var viewportBottom = window.scrollY + document.documentElement.clientHeight;
    btn.style.left = left + "px";
    btn.style.top = (below + 48 <= viewportBottom ? below : above) + "px";
    btn.classList.add("show");
  }

  // Selection events must be handled synchronously: a debounced
  // variant (setTimeout) never fired on Android WebView while the
  // system selection ActionMode was up.  showBtn only re-reads the
  // selection rect, so the per-event cost is negligible.
  document.addEventListener("selectionchange", function () {
    var s = window.getSelection();
    var raw = s && s.rangeCount > 0 ? s.toString() : "";
    var t = raw && raw.length <= 80 ? raw.replace(/\\s+/g, " ").trim() : "";
    if (t) showBtn(t); else hideBtn();
  });
  document.addEventListener("click", function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest("a, #lute-local-lookup, button")) return;
    if (document.caretRangeFromPoint) {
      var range = document.caretRangeFromPoint(e.clientX, e.clientY);
      if (!range) return;
      var s = window.getSelection();
      s.removeAllRanges();
      s.addRange(range);
      if (s.modify) {
        s.modify("extend", "backward", "word");
        s.modify("extend", "forward", "word");
      }
      var text = selectionText();
      if (text) showBtn(text); else hideBtn();
    }
  });

  btn.addEventListener("click", function (e) {
    e.stopPropagation();
    var text = btn.dataset.text || "";
    hideBtn();
    var s = window.getSelection();
    if (s) s.removeAllRanges();
    if (text) callFlutter("localEpubLookup", { text: text });
  });

  /* ---- scroll reporting ---- */

  var scrollRaf = 0;
  function reportScroll() {
    var doc = document.documentElement;
    callFlutter("localEpubScroll", {
      top: window.scrollY,
      max: Math.max(0, doc.scrollHeight - window.innerHeight)
    });
  }
  window.addEventListener("scroll", function () {
    if (scrollRaf) return;
    scrollRaf = requestAnimationFrame(function () {
      scrollRaf = 0;
      reportScroll();
    });
  }, { passive: true });

  document.addEventListener("DOMContentLoaded", function () {
    fitFixed();
    reportScroll();
  });
})();
''';
