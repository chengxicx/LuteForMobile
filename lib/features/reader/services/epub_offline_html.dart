import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'epub_offline_store.dart';

/// Pure helpers for the EPUB offline pack: everything here is string /
/// DOM surgery with no I/O, so the whole file is unit-testable as plain
/// Dart (same philosophy as page_load_strategy.dart).
///
/// The pages being rewritten and mined are the server's
/// `/read/epub_render/<bookId>/<page>` documents, whose structural
/// markers (the `epub-look-*` class, the `var look = "..."` boot line,
/// `LUTE_FURIGANA`, `#lute-epub-tokens`, `data-epub-css`) are pinned by
/// the server template *and* its tests (`tests/unit/book/
/// test_epub_reader_mode.py`), so these substitutions are contracts, not
/// guesses.

/// Rewrites a canonical fetch (`look=original&furigana=0&triple=1`) of
/// the standalone chapter page into the requested look / furigana /
/// triple-tap variant, the same way the server's query params would
/// have rendered it.
///
/// Unknown or absent markers are left untouched -- the page then simply
/// boots with the packed defaults, which is a safe degradation, never a
/// broken one.
String rewriteEpubRenderHtml(
  String html, {
  required String look,
  required bool furigana,
  required bool triple,
}) {
  var out = html;

  if (look == 'night' || look == 'theme' || look == 'original') {
    // The #thetext wrapper class: original -> epub-look-original,
    // night -> epub-look-night, theme -> no look class at all.
    if (look == 'theme') {
      out = out
          .replaceFirst(' epub-look-original', '')
          .replaceFirst(' epub-look-night', '');
    } else {
      final target = look == 'night' ? 'epub-look-night' : 'epub-look-original';
      out = out.replaceFirst(
        RegExp(' epub-look-(original|night)'),
        ' $target',
      );
    }
    // Boot script: EpubReader.setLook reads this back.
    out = out.replaceFirst(
      RegExp('var look = "(original|night|theme)";'),
      'var look = "$look";',
    );
  }

  if (furigana) {
    out = out.replaceFirst(
      'var LUTE_FURIGANA = { enabled: false',
      'var LUTE_FURIGANA = { enabled: true',
    );
    out = out.replaceFirst(
      'var furiganaLoaded = false;',
      'var furiganaLoaded = true;',
    );
    // The packed page (furigana=0) has no furigana <script> tag; inject
    // one ahead of the reader script, mirroring the server template's
    // order (furigana js, then reader js).  Guarded on the tag form:
    // the page's own FURIGANA_SRC variable names the file even when the
    // script tag is absent.
    if (!RegExp(r'<script[^>]*lute-furigana\.js').hasMatch(out)) {
      const tag =
          '<script type="text/javascript" src="/static/js/lute-furigana.js" charset="utf-8" defer></script>';
      out = out.replaceFirstMapped(
        RegExp(r'(<script[^>]*lute-epub-reader\.js[^>]*></script>)'),
        (m) => '$tag\n  ${m[1]}',
      );
    }
  }

  if (triple) {
    out = out.replaceFirst(
      'var tripleEnabled = false;',
      'var tripleEnabled = true;',
    );
  }

  return out;
}

/// Collects every same-origin asset URL path a chapter page references:
/// link/script/img/source attributes, `srcset` candidates, the two
/// scoped stylesheets on `#epub-chapter`, and `url(...)` occurrences in
/// inline styles.  Returns normalized store paths (no leading slash).
Set<String> extractAssetPaths(String pageHtml, {String? serverOrigin}) {
  final document = html_parser.parse(pageHtml);
  final paths = <String>{};

  void add(String? raw) {
    final normalized = EpubOfflineStore.normalizeUrlPath(
      raw ?? '',
      serverOrigin: serverOrigin,
    );
    if (normalized != null) paths.add(normalized);
  }

  for (final el in document.querySelectorAll('link[href]')) {
    add(el.attributes['href']);
  }
  for (final el in document.querySelectorAll('script[src]')) {
    add(el.attributes['src']);
  }
  for (final el in document.querySelectorAll('img[src]')) {
    add(el.attributes['src']);
  }
  for (final el in document.querySelectorAll('source[src]')) {
    add(el.attributes['src']);
  }
  // srcset: comma-separated `url descriptor` candidates.
  for (final el in document.querySelectorAll('[srcset]')) {
    for (final candidate in (el.attributes['srcset'] ?? '').split(',')) {
      add(candidate.trim().split(RegExp(r'\s+')).firstOrNull);
    }
  }

  final chapter = document.querySelector('#epub-chapter');
  if (chapter != null) {
    add(chapter.attributes['data-epub-css']);
    add(chapter.attributes['data-epub-orig-css']);
  }

  // url(...) in inline styles (epub chapters paint backgrounds this
  // way).  The regex is permissive; normalizeUrlPath filters garbage.
  for (final match in RegExp(
    r'''url\(\s*["']?([^"')]+?)["']?\s*\)''',
  ).allMatches(pageHtml)) {
    add(match.group(1));
  }

  return paths;
}

extension _FirstOrNull on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}

/// Every same-origin reference inside a stylesheet: `url(...)` targets
/// (fonts, images) and `@import`ed files, resolved against the css
/// file's own directory ([cssPath], a normalized store path).
Set<String> extractCssRefs(String cssText, String cssPath) {
  final dir = p.posix.dirname(cssPath);
  final refs = <String>{};

  void addRaw(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return;
    if (value.startsWith('data:') || value.startsWith('#')) return;
    String? normalized;
    if (value.startsWith('/') || value.contains('://')) {
      normalized = EpubOfflineStore.normalizeUrlPath(value);
    } else {
      final joined = p.posix.normalize(p.posix.join(dir, value));
      normalized = joined.startsWith('../')
          ? null
          : EpubOfflineStore.normalizeUrlPath(joined);
    }
    if (normalized != null) refs.add(normalized);
  }

  for (final match in RegExp(
    r'''url\(\s*["']?([^"')]+?)["']?\s*\)''',
  ).allMatches(cssText)) {
    addRaw(match.group(1) ?? '');
  }
  for (final match in RegExp(
    r'''@import\s+(?:url\(\s*["']?[^"')]+?["']?\s*\)|["']([^"';]+)["'])''',
  ).allMatches(cssText)) {
    final quoted = match.group(1);
    if (quoted != null) addRaw(quoted);
  }

  return refs;
}

/// The per-paragraph word-token batches the page's furigana script will
/// POST to `/read/shadowing/readings`, plus the language id those
/// requests carry -- the prefetcher asks for exactly these bodies so
/// the local server can replay them offline.
///
/// Mirrors `lute-furigana.js`: only `span.word` tokens (wo_id > 0) are
/// batched, grouped by the paragraph id, in stream order.
({int langId, List<List<String>> batches})? extractReadingBatches(
  String pageHtml,
) {
  final document = html_parser.parse(pageHtml);
  final tokensNode = document.querySelector('#lute-epub-tokens');
  if (tokensNode == null) return null;

  List<dynamic>? tokens;
  try {
    tokens = jsonDecode(tokensNode.text) as List<dynamic>?;
  } catch (_) {
    return null;
  }
  if (tokens == null) return null;

  var langId = 0;
  for (final script in document.querySelectorAll('script')) {
    final match = RegExp(
      r'LUTE_FURIGANA\s*=\s*\{[^}]*?\blangId\s*:\s*(\d+)',
    ).firstMatch(script.text);
    if (match != null) {
      langId = int.tryParse(match.group(1) ?? '') ?? 0;
      break;
    }
  }
  if (langId <= 0) return null;

  // Paragraph id -> word tokens, first-appearance order.
  final order = <int>[];
  final batches = <int, List<String>>{};
  for (final raw in tokens) {
    if (raw is! List || raw.length < 3) continue;
    final text = raw[0]?.toString() ?? '';
    final wid = raw[1] is num ? (raw[1] as num).toInt() : 0;
    if (wid <= 0 || text.isEmpty) continue;
    final paragraph =
        raw.length > 4 && raw[4] is num ? (raw[4] as num).toInt() : 0;
    final batch = batches.putIfAbsent(paragraph, () {
      order.add(paragraph);
      return <String>[];
    });
    batch.add(text);
  }

  return (langId: langId, batches: order.map((k) => batches[k]!).toList());
}
