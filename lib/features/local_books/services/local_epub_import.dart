import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'local_epub_page.dart';

/// One spine chapter of a locally imported book.
class LocalEpubChapterInfo {
  const LocalEpubChapterInfo({
    required this.path,
    required this.title,
    this.viewportWidth,
    this.viewportHeight,
  });

  /// Zip-relative path of the chapter's (sanitised) reading page, e.g.
  /// `OEBPS/text/ch1.xhtml` -- also its URL on the local server.
  final String path;
  final String title;
  final int? viewportWidth;
  final int? viewportHeight;

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    if (viewportWidth != null) 'vw': viewportWidth,
    if (viewportHeight != null) 'vh': viewportHeight,
  };

  static LocalEpubChapterInfo fromJson(Map<String, dynamic> json) =>
      LocalEpubChapterInfo(
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        viewportWidth: (json['vw'] as num?)?.toInt(),
        viewportHeight: (json['vh'] as num?)?.toInt(),
      );
}

/// The parsed book, persisted as `book.json` beside the extraction.
class LocalEpubData {
  const LocalEpubData({
    required this.id,
    required this.title,
    required this.author,
    required this.chapters,
  });

  final String id;
  final String title;
  final String author;
  final List<LocalEpubChapterInfo> chapters;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };

  static LocalEpubData fromJson(Map<String, dynamic> json) => LocalEpubData(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    author: json['author'] as String? ?? '',
    chapters: (json['chapters'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(LocalEpubChapterInfo.fromJson)
        .toList(),
  );
}

class LocalEpubImportException implements Exception {
  const LocalEpubImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Imports an .epub entirely on-device (Phase 2: no server).
///
/// Layout written under [rootDir] (default: the app documents dir's
/// `local_epub/`, injectable for tests):
///
/// * `book.epub` -- the untouched original (the "upgrade to server"
///   flow re-uploads exactly this file);
/// * `extract/<zip path>` -- the archive mirrored at its own paths, so
///   relative references inside chapters and stylesheets resolve as-is
///   when the local server serves them; spine chapters are *replaced
///   in place* by their sanitised standalone reading pages;
/// * `book.json` -- [LocalEpubData].
///
/// The pipeline mirrors the server's `lute/book/epub_parser.py` +
/// `epub_extract.py` where it must (container → OPF, spine order, TOC
/// titles, drop-tags sanitisation, pixel-viewport fixed-layout
/// detection) and deliberately diverges where it can (no CSS scoping,
/// no URL rewriting, no text/token stream).
class LocalEpubImporter {
  LocalEpubImporter({required Future<String> Function() resolveRoot})
    : _resolveRoot = resolveRoot;

  final Future<String> Function() _resolveRoot;

  /// Extracted-content cap, same guard value as the server's
  /// `epub_extract._MAX_TOTAL_BYTES`.
  static const int maxExtractBytes = 512 * 1024 * 1024;

  static const Set<String> _skipMembers = {'mimetype'};

  /// Imports [epubPath]; returns the parsed book (id included).
  Future<LocalEpubData> importFromFile(
    String epubPath, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('reading');
    final bytes = await File(epubPath).readAsBytes();
    return importFromBytes(bytes, filename: p.basename(epubPath));
  }

  /// The import proper, on in-memory bytes (tests build zips here).
  Future<LocalEpubData> importFromBytes(
    List<int> bytes, {
    String filename = 'book.epub',
  }) async {
    final rootDir = await _resolveRoot();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw LocalEpubImportException('Not a valid EPUB file: $e');
    }

    final id = _newId();
    final bookDir = Directory(p.join(rootDir, id));
    final extractDir = Directory(p.join(bookDir.path, 'extract'));

    // 1. Mirror the archive (mimetype/META-INF carry nothing readable).
    var total = 0;
    final zipNames = <String>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = _safeZipPath(file.name);
      if (name == null) continue;
      if (_skipMembers.contains(name) || name.startsWith('META-INF/')) {
        continue;
      }
      final data = file.content as List<int>;
      total += data.length;
      if (total > maxExtractBytes) {
        await bookDir.delete(recursive: true).catchError((_) => bookDir);
        throw const LocalEpubImportException(
          'This EPUB extracts to more than 512 MB and was refused.',
        );
      }
      zipNames.add(name);
      final target = File(p.joinAll([extractDir.path, ...name.split('/')]));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(data, flush: true);
    }

    // 2. Container → OPF.  The container description is read straight
    //    from the archive: it is never extracted (see the skip above).
    final containerMember = archive.files
        .where((f) => f.isFile && f.name == 'META-INF/container.xml')
        .firstOrNull;
    if (containerMember == null) {
      throw const LocalEpubImportException(
        'Not a valid EPUB file: missing META-INF/container.xml.',
      );
    }
    final opfPath = _rootFilePath(
      utf8.decode(containerMember.content as List<int>, allowMalformed: true),
    );
    if (opfPath == null || !zipNames.contains(opfPath)) {
      throw const LocalEpubImportException(
        'Not a valid EPUB file: no readable package document.',
      );
    }

    // 3. OPF: metadata, manifest, spine (+ TOC titles).
    final opfText = utf8.decode(
      await File(p.joinAll([extractDir.path, ...opfPath.split('/')]))
          .readAsBytes(),
      allowMalformed: true,
    );
    final opfDir = p.posix.dirname(opfPath);
    final parsed = _parseOpf(opfText);

    final tocLabels = <String, String>{};
    final tocHref = parsed.tocHref;
    if (tocHref != null) {
      final tocPath = _resolveZipPath(opfDir, tocHref);
      if (zipNames.contains(tocPath)) {
        try {
          final tocText = utf8.decode(
            await File(p.joinAll([extractDir.path, ...tocPath.split('/')]))
                .readAsBytes(),
            allowMalformed: true,
          );
          tocLabels.addAll(_parseTocLabels(tocText, p.posix.dirname(tocPath)));
        } catch (_) {}
      }
    }

    // 4. Each spine chapter becomes its sanitised standalone page,
    //    written back at the same zip path so relative refs survive.
    final chapters = <LocalEpubChapterInfo>[];
    for (var i = 0; i < parsed.spineHrefs.length; i++) {
      final href = parsed.spineHrefs[i];
      final zipPath = _resolveZipPath(opfDir, href);
      if (!zipNames.contains(zipPath)) continue;
      final file = File(p.joinAll([extractDir.path, ...zipPath.split('/')]));
      final raw = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      final page = buildLocalChapterPage(raw);
      await file.writeAsString(page.html, flush: true);

      final viewport = page.viewport;
      chapters.add(LocalEpubChapterInfo(
        path: zipPath,
        title: tocLabels[zipPath] ?? 'Chapter ${i + 1}',
        viewportWidth: viewport?.width,
        viewportHeight: viewport?.height,
      ));
    }
    if (chapters.isEmpty) {
      throw const LocalEpubImportException(
        'This EPUB has no readable chapters.',
      );
    }

    // 5. Keep the original for the server-upgrade flow + book.json.
    await File(p.join(bookDir.path, 'book.epub')).writeAsBytes(bytes);
    final data = LocalEpubData(
      id: id,
      title: parsed.title.isNotEmpty
          ? parsed.title
          : p.basenameWithoutExtension(filename),
      author: parsed.author,
      chapters: chapters,
    );
    await File(p.join(bookDir.path, 'book.json')).writeAsString(
      jsonEncode(data.toJson()),
      flush: true,
    );
    return data;
  }

  /// Re-sanitises a book's spine chapters from the kept original
  /// .epub, overwriting the extracted pages in place.  Used when the
  /// app's page template is newer than the one the book was imported
  /// with ([localEpubPageVersion]) -- the reading page carries the
  /// lookup UI, so a stale template silently degrades it.
  ///
  /// Returns the refreshed [LocalEpubData] (chapter paths are stable;
  /// titles may improve if the TOC parse does better now).
  Future<LocalEpubData> rebuildPages(LocalEpubData data) async {
    final rootDir = await _resolveRoot();
    final bookDir = Directory(p.join(rootDir, data.id));
    final original = File(p.join(bookDir.path, 'book.epub'));
    if (!await original.exists()) return data;

    final archive = ZipDecoder().decodeBytes(await original.readAsBytes());
    final bookJson = File(p.join(bookDir.path, 'book.json'));
    final keptEpub = await original.readAsBytes();

    // Rewrite each spine chapter from the archive.
    final freshChapters = <LocalEpubChapterInfo>[];
    for (final chapter in data.chapters) {
      final member = archive.files
          .where((f) => f.isFile && f.name == chapter.path)
          .firstOrNull;
      if (member == null) {
        freshChapters.add(chapter);
        continue;
      }
      final raw = utf8.decode(member.content as List<int>, allowMalformed: true);
      final page = buildLocalChapterPage(raw);
      final target = File(
        p.joinAll([bookDir.path, 'extract', ...chapter.path.split('/')]),
      );
      await target.writeAsString(page.html, flush: true);
      freshChapters.add(LocalEpubChapterInfo(
        path: chapter.path,
        title: chapter.title,
        viewportWidth: page.viewport?.width,
        viewportHeight: page.viewport?.height,
      ));
    }

    final refreshed = LocalEpubData(
      id: data.id,
      title: data.title,
      author: data.author,
      chapters: freshChapters,
    );
    await bookJson.writeAsString(jsonEncode(refreshed.toJson()), flush: true);
    // Restore the original untouched (the upgrade flow re-uploads it).
    await original.writeAsBytes(keptEpub, flush: true);
    return refreshed;
  }

  String _newId() {
    final rand = Random().nextInt(0xffff).toRadixString(36).padLeft(3, '0');
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }

  /// A zip member path that is safe to extract, or null (absolute,
  /// traversal, or empty names are skipped).
  static String? _safeZipPath(String name) {
    final normalized = name.replaceAll('\\', '/').trim();
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    final segments = normalized.split('/').where((s) => s.isNotEmpty);
    if (segments.isEmpty || segments.any((s) => s == '..')) return null;
    return segments.join('/');
  }

  /// `META-INF/container.xml` → the OPF's zip path.
  static String? _rootFilePath(String containerXml) {
    try {
      final doc = XmlDocument.parse(containerXml);
      for (final el in doc.descendants.whereType<XmlElement>()) {
        if (el.name.local != 'rootfile') continue;
        final fullPath = el.attributes
            .where((a) => a.name.local == 'full-path')
            .map((a) => a.value)
            .firstOrNull;
        if (fullPath != null && fullPath.isNotEmpty) {
          return _safeZipPath(fullPath);
        }
      }
      return null;
    } on XmlException {
      return null;
    }
  }

  static _OpfData _parseOpf(String opfText) {
    final doc = XmlDocument.parse(opfText);

    String? title;
    String? author;
    for (final el in doc.descendants.whereType<XmlElement>()) {
      final local = el.name.local;
      if (title == null && local == 'title' && el.text.trim().isNotEmpty) {
        title = el.text.trim();
      } else if (author == null &&
          local == 'creator' &&
          el.text.trim().isNotEmpty) {
        author = el.text.trim();
      }
    }

    // manifest id → (href, media-type, properties)
    final manifest = <String, (String, String?, String?)>{};
    XmlElement? spine;
    for (final el in doc.descendants.whereType<XmlElement>()) {
      switch (el.name.local) {
        case 'item':
          final id = _attr(el, 'id');
          final href = _attr(el, 'href');
          if (id != null && href != null) {
            manifest[id] = (href, _attr(el, 'media-type'), _attr(el, 'properties'));
          }
        case 'spine':
          spine ??= el;
      }
    }

    final tocAttr = spine == null ? null : _attr(spine!, 'toc');
    var tocHref = _navHrefFromProperties(manifest);
    if (tocAttr != null && manifest.containsKey(tocAttr)) {
      tocHref = manifest[tocAttr]!.$1;
    }

    final spineHrefs = <String>[];
    if (spine != null) {
      for (final el in spine.descendants.whereType<XmlElement>()) {
        if (el.name.local != 'itemref') continue;
        final idref = _attr(el, 'idref');
        if (idref == null) continue;
        final item = manifest[idref];
        if (item == null) continue;
        final mediaType = item.$2 ?? '';
        if (mediaType.isNotEmpty &&
            !mediaType.contains('html') &&
            !mediaType.contains('xml')) {
          continue;
        }
        spineHrefs.add(item.$1);
      }
    }

    return _OpfData(
      title: title ?? '',
      author: author ?? '',
      tocHref: tocHref,
      spineHrefs: spineHrefs,
    );
  }

  /// EPUB3: the manifest item with `properties="nav"`.
  static String? _navHrefFromProperties(
    Map<String, (String, String?, String?)> manifest,
  ) {
    for (final entry in manifest.values) {
      final props = entry.$3;
      if (props != null && props.split(RegExp(r'\s+')).contains('nav')) {
        return entry.$1;
      }
    }
    return null;
  }

  /// TOC label map: chapter zip path → title.
  ///
  /// Handles both shapes: EPUB2 NCX (`navPoint/navLabel/text` +
  /// `content@src`) and EPUB3 nav documents (`nav a[href]`).
  static Map<String, String> _parseTocLabels(String tocText, String tocDir) {
    final labels = <String, String>{};
    try {
      final doc = XmlDocument.parse(tocText);
      final isNcx = doc.rootElement.name.local == 'ncx';
      if (isNcx) {
        for (final navPoint
            in doc.descendants.whereType<XmlElement>().where(
                  (el) => el.name.local == 'navPoint',
                )) {
          final label = navPoint.descendants
              .whereType<XmlElement>()
              .where((el) => el.name.local == 'text')
              .map((el) => el.text.trim())
              .firstOrNull;
          final src = navPoint.descendants
              .whereType<XmlElement>()
              .where((el) => el.name.local == 'content')
              .map((el) => _attr(el, 'src'))
              .firstOrNull;
          if (label != null && label.isNotEmpty && src != null) {
            labels[_resolveZipPath(tocDir, src)] = label;
          }
        }
      } else {
        for (final anchor in doc.descendants.whereType<XmlElement>().where(
              (el) => el.name.local == 'a',
            )) {
          final href = _attr(anchor, 'href');
          final label = anchor.text.trim();
          if (href != null && label.isNotEmpty) {
            labels.putIfAbsent(_resolveZipPath(tocDir, href), () => label);
          }
        }
      }
    } on XmlException {
      // A broken TOC costs chapter titles, not the import.
    }
    return labels;
  }

  /// Resolves an OPF/TOC href (URL-encoded, possibly relative, possibly
  /// with a fragment) to a zip path.
  static String _resolveZipPath(String baseDir, String href) {
    var value = href.split('#').first;
    if (value.isEmpty) return baseDir;
    try {
      value = Uri.decodeComponent(value);
    } catch (_) {}
    final joined = baseDir.isEmpty
        ? value
        : p.posix.normalize(p.posix.join(baseDir, value));
    return joined.startsWith('../') ? value : joined;
  }

  static String? _attr(XmlElement el, String name) {
    for (final attr in el.attributes) {
      if (attr.name.local == name) return attr.value;
    }
    return null;
  }
}

class _OpfData {
  const _OpfData({
    required this.title,
    required this.author,
    this.tocHref,
    required this.spineHrefs,
  });

  final String title;
  final String author;
  final String? tocHref;
  final List<String> spineHrefs;
}
