import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manifest of one book's offline pack.
///
/// Kept as a hand-rolled JSON file (not Hive): it is tiny, and the local
/// server answers from these files before any box is open.
class EpubPackManifest {
  final int bookId;
  String title;
  int pageCount;
  bool complete;
  final Map<int, int> pageTimestamps;
  final List<String> urls;

  EpubPackManifest({
    required this.bookId,
    this.title = '',
    this.pageCount = 0,
    this.complete = false,
    Map<int, int>? pageTimestamps,
    List<String>? urls,
  }) : pageTimestamps = pageTimestamps ?? {},
       urls = urls ?? [];

  bool get hasAllPages =>
      pageCount > 0 &&
      pageTimestamps.length >= pageCount &&
      List.generate(pageCount, (i) => i + 1).every(pageTimestamps.containsKey);

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'title': title,
    'pageCount': pageCount,
    'complete': complete,
    'pages': pageTimestamps.map((k, v) => MapEntry('$k', v)),
    'urls': urls,
  };

  static EpubPackManifest fromJson(Map<String, dynamic> json) {
    final pages = <int, int>{};
    final rawPages = json['pages'];
    if (rawPages is Map) {
      rawPages.forEach((key, value) {
        final page = int.tryParse('$key');
        final ts = value is num ? value.toInt() : int.tryParse('$value');
        if (page != null && ts != null) pages[page] = ts;
      });
    }
    final urls = (json['urls'] as List<dynamic>? ?? const [])
        .map((u) => u.toString())
        .toList();
    return EpubPackManifest(
      bookId: json['bookId'] as int,
      title: json['title'] as String? ?? '',
      pageCount: json['pageCount'] as int? ?? 0,
      complete: json['complete'] as bool? ?? false,
      pageTimestamps: pages,
      urls: urls,
    );
  }
}

/// Disk store for the reader-mode EPUB offline packs.
///
/// Layout under [rootDir] (default: `<app cache>/epub_offline`, resolved
/// lazily so plain unit tests can inject a temp dir and stay plugin-free):
///
/// * `files/<url path>` -- every mirrored URL path, e.g.
///   `files/read/epub_render/3/12` or `files/static/epub/<uuid>/x.jpg`.
///   Query strings never take part: server asset URLs are content-hashed
///   (`vstatic`) and the local server ignores them anyway.
/// * `readings/<md5>.json` -- raw `POST /read/shadowing/readings`
///   responses, keyed by (language_id, tokens).  Shared across books:
///   the same paragraph asked twice must give the same answer.
/// * `packs/<bookId>.json` -- [EpubPackManifest].
///
/// A pack deliberately has no TTL: chapters do not change behind their
/// content-hashed URLs, statuses are corrected natively (the reader
/// pushes `setStatus` into the page), and the outbox flush drops the
/// pages it just corrected (see [removePages]).
class EpubOfflineStore {
  final String? rootDir;
  String? _resolvedRoot;

  EpubOfflineStore({this.rootDir});

  Future<String> _root() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;
    // Injected root first: tests (and any non-Flutter embedder) never
    // touch the plugin.
    final resolved =
        rootDir ??
        p.join((await getApplicationCacheDirectory()).path, 'epub_offline');
    _resolvedRoot = resolved;
    return resolved;
  }

  File _fileUnder(String root, String rel) {
    return File(p.joinAll([root, ...rel.split('/')]));
  }

  /// Normalizes a URL or path to a store path without a leading slash
  /// (`static/epub/x/lute.css`), or null when it is not storable: a
  /// foreign origin, a `data:`/`#` reference, empty, or escaping the
  /// root with `..`.
  static String? normalizeUrlPath(String raw, {String? serverOrigin}) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('#')) return null;
    if (value.startsWith('data:')) return null;

    if (value.contains('://')) {
      if (serverOrigin == null || serverOrigin.isEmpty) return null;
      final uri = Uri.tryParse(value);
      final own = Uri.tryParse(serverOrigin);
      if (uri == null ||
          own == null ||
          !uri.hasScheme ||
          uri.host != own.host ||
          uri.port != own.port) {
        return null;
      }
      value = uri.path;
    } else if (value.startsWith('//')) {
      return null;
    }

    value = value.split('?').first.split('#').first;
    if (value.startsWith('/')) value = value.substring(1);
    value = value.trim();
    if (value.isEmpty) return null;

    final segments = value.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty || segments.any((s) => s == '..')) return null;
    return segments.join('/');
  }

  Future<bool> hasFile(String urlPath) async {
    final root = await _root();
    return _fileUnder(root, p.join('files', urlPath)).exists();
  }

  Future<Uint8List?> readBytes(String urlPath) async {
    final root = await _root();
    try {
      final file = _fileUnder(root, p.join('files', urlPath));
      if (!await file.exists()) return null;
      return Uint8List.fromList(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  Future<String?> readText(String urlPath) async {
    final bytes = await readBytes(urlPath);
    if (bytes == null) return null;
    return utf8.decode(bytes);
  }

  Future<void> writeBytes(String urlPath, List<int> bytes) async {
    final root = await _root();
    final file = _fileUnder(root, p.join('files', urlPath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<void> writeText(String urlPath, String text) =>
      writeBytes(urlPath, utf8.encode(text));

  // ---- readings ----

  /// Canonical key for one readings request: the page batches by
  /// paragraph and posts `{language_id, tokens}`; `full_text` is derived
  /// from the tokens, so it is deliberately not part of the identity.
  static String canonicalReadingsKey(int languageId, List<String> tokens) {
    return jsonEncode([languageId, tokens]);
  }

  String readingsFileName(String canonicalKey) {
    return '${md5.convert(utf8.encode(canonicalKey)).toString()}.json';
  }

  Future<bool> hasReadings(String canonicalKey) async {
    final root = await _root();
    return _fileUnder(
      root,
      p.join('readings', readingsFileName(canonicalKey)),
    ).exists();
  }

  Future<void> writeReadings(String canonicalKey, String responseBody) async {
    final root = await _root();
    final file = _fileUnder(
      root,
      p.join('readings', readingsFileName(canonicalKey)),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(responseBody, flush: true);
  }

  Future<String?> readReadings(String canonicalKey) async {
    final root = await _root();
    try {
      final file = _fileUnder(
        root,
        p.join('readings', readingsFileName(canonicalKey)),
      );
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  // ---- manifest ----

  Future<EpubPackManifest?> manifestFor(int bookId) async {
    final root = await _root();
    try {
      final file = _fileUnder(root, p.join('packs', '$bookId.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return EpubPackManifest.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveManifest(EpubPackManifest manifest) async {
    final root = await _root();
    final file = _fileUnder(root, p.join('packs', '${manifest.bookId}.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  }

  static String pageUrlPath(int bookId, int pageNum) =>
      'read/epub_render/$bookId/$pageNum';

  Future<bool> hasPage(int bookId, int pageNum) =>
      hasFile(pageUrlPath(bookId, pageNum));

  /// Drop the pack's page HTMLs (the tokens they embed went stale when
  /// the outbox delivered the user's offline edits).  Assets stay: they
  /// are content-hashed and the next page fetch reuses them; the pages
  /// are re-fetched by the next prefetch pass.
  Future<void> removePages(int bookId, List<int> pages) async {
    final manifest = await manifestFor(bookId);
    if (manifest == null) return;
    var changed = false;
    final root = await _root();
    for (final page in pages) {
      if (manifest.pageTimestamps.remove(page) != null) changed = true;
      try {
        final file = _fileUnder(
          root,
          p.join('files', pageUrlPath(bookId, page)),
        );
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (changed) {
      manifest.complete = manifest.hasAllPages;
      await saveManifest(manifest);
    }
  }

  /// Deletes the whole pack: the chapter pages, the book's own extracted
  /// assets (`static/epub/<uuid>/...`), and the manifest.  Shared files
  /// (styles.css, the reader scripts, theme css) and readings stay --
  /// other packs and the reading cache still reference them.
  Future<void> deletePack(int bookId) async {
    final manifest = await manifestFor(bookId);
    final root = await _root();
    final filesRoot = Directory(p.join(root, 'files'));

    // Chapter pages: one directory per book under read/epub_render.
    final renderDir = Directory(
      p.join(filesRoot.path, 'read', 'epub_render', '$bookId'),
    );
    try {
      if (await renderDir.exists()) await renderDir.delete(recursive: true);
    } catch (_) {}

    // The book's extracted package (images, fonts, scoped stylesheets).
    final epubDirs = <String>{};
    for (final url in manifest?.urls ?? const <String>[]) {
      if (url.startsWith('static/epub/')) {
        final segments = url.split('/');
        if (segments.length > 2) epubDirs.add(segments.sublist(0, 3).join('/'));
      }
    }
    for (final dir in epubDirs) {
      try {
        final target = Directory(p.joinAll([filesRoot.path, ...dir.split('/')]));
        if (await target.exists()) await target.delete(recursive: true);
      } catch (_) {}
    }

    try {
      final file = _fileUnder(root, p.join('packs', '$bookId.json'));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> deleteAll() async {
    final root = await _root();
    try {
      final dir = Directory(root);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _resolvedRoot = null;
  }

  /// Total bytes used by every pack, reading and asset on disk.
  Future<int> diskUsageBytes() async {
    final root = await _root();
    final dir = Directory(root);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }
}
