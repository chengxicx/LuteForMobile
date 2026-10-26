import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_epub_import.dart';

/// The shelf record of one locally imported book.  Chapter details
/// (paths, titles, viewports) live in `book.json` on disk -- only the
/// list-shaped fields a shelf needs are kept here, so opening the box
/// stays cheap no matter how fat the books are.
class LocalBookRecord {
  const LocalBookRecord({
    required this.id,
    required this.title,
    required this.author,
    required this.chapterCount,
    this.lastChapter = 0,
    this.dictFilename,
    this.serverBookId,
    this.pageVersion = 0,
    required this.importedAt,
  });

  final String id;
  final String title;
  final String author;
  final int chapterCount;

  /// 0-based chapter the reader should resume at.
  final int lastChapter;

  /// Pool filename of this book's remembered lookup dictionary.
  final String? dictFilename;

  /// Set once the book was uploaded to the server ("upgrade").
  final int? serverBookId;

  /// Reading-page template the extraction was built with (0 = pre-2.0
  /// imports that predate the field).  The reader rebuilds the pages
  /// from the kept .epub when this lags [localEpubPageVersion].
  final int pageVersion;

  final int importedAt;

  LocalBookRecord copyWith({
    int? lastChapter,
    String? dictFilename,
    bool clearDict = false,
    int? serverBookId,
    int? pageVersion,
  }) =>
      LocalBookRecord(
        id: id,
        title: title,
        author: author,
        chapterCount: chapterCount,
        lastChapter: lastChapter ?? this.lastChapter,
        dictFilename: clearDict ? null : (dictFilename ?? this.dictFilename),
        serverBookId: serverBookId ?? this.serverBookId,
        pageVersion: pageVersion ?? this.pageVersion,
        importedAt: importedAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'chapterCount': chapterCount,
    'lastChapter': lastChapter,
    'dictFilename': dictFilename,
    'serverBookId': serverBookId,
    'pageVersion': pageVersion,
    'importedAt': importedAt,
  };

  static LocalBookRecord fromJson(Map<String, dynamic> json) =>
      LocalBookRecord(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        chapterCount: json['chapterCount'] as int? ?? 0,
        lastChapter: json['lastChapter'] as int? ?? 0,
        dictFilename: json['dictFilename'] as String?,
        serverBookId: json['serverBookId'] as int?,
        pageVersion: json['pageVersion'] as int? ?? 0,
        importedAt: json['importedAt'] as int? ?? 0,
      );
}

/// Bookshelf + progress store for locally imported EPUBs.
///
/// The list is a Hive box of JSON strings (no codegen adapters); the
/// reading position per chapter is a SharedPreferences double, keyed
/// the same way the server-book epub reader keys its scroll offsets.
/// Both the extraction root and the box name are injectable so plain
/// Dart tests can run without a plugin registry.
class LocalBookStore {
  LocalBookStore({String? rootDir, String boxName = 'local_books'})
    : _rootDir = rootDir,
      _boxName = boxName;

  final String? _rootDir;
  final String _boxName;
  String? _resolvedRoot;
  static const String _boxPrefix = 'local_book_';

  Future<String> root() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;
    // Injected root first: tests never touch the plugin.
    final resolved =
        _rootDir ??
        p.join((await getApplicationDocumentsDirectory()).path, 'local_epub');
    _resolvedRoot = resolved;
    return resolved;
  }

  Future<String> bookDir(String id) async => p.join(await root(), id);

  // ---- box ----

  Future<Box<String>> _getBox() async {
    if (!Hive.isBoxOpen(_boxName)) {
      final dir = await getApplicationCacheDirectory();
      await Hive.initFlutter(dir.path);
      await Hive.openBox<String>(_boxName);
    }
    return Hive.openBox<String>(_boxName);
  }

  Future<List<LocalBookRecord>> list() async {
    final box = await _getBox();
    final records = box.values
        .map((raw) {
          try {
            return LocalBookRecord.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<LocalBookRecord>()
        .toList();
    records.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return records;
  }

  Future<LocalBookRecord?> get(String id) async {
    final box = await _getBox();
    final raw = box.get('$_boxPrefix$id');
    if (raw == null) return null;
    try {
      return LocalBookRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> upsert(LocalBookRecord record) async {
    final box = await _getBox();
    await box.put('$_boxPrefix${record.id}', jsonEncode(record.toJson()));
  }

  Future<void> setLastChapter(String id, int chapter) async {
    final record = await get(id);
    if (record == null) return;
    await upsert(record.copyWith(lastChapter: chapter));
  }

  Future<void> setDictFilename(String id, String? filename) async {
    final record = await get(id);
    if (record == null) return;
    await upsert(
      record.copyWith(dictFilename: filename, clearDict: filename == null),
    );
  }

  Future<void> setServerBookId(String id, int serverBookId) async {
    final record = await get(id);
    if (record == null) return;
    await upsert(record.copyWith(serverBookId: serverBookId));
  }

  /// Deletes the record and the whole on-disk book (extraction +
  /// original .epub).  The server book, if any, is untouched.
  Future<void> delete(String id) async {
    final box = await _getBox();
    await box.delete('$_boxPrefix$id');
    try {
      final dir = Directory(await bookDir(id));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ---- book.json ----

  Future<LocalEpubData?> loadBookData(String id) async {
    try {
      final file = File(p.join(await bookDir(id), 'book.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return LocalEpubData.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<String?> epubFilePath(String id) async {
    final file = File(p.join(await bookDir(id), 'book.epub'));
    return await file.exists() ? file.path : null;
  }

  // ---- progress ----

  Future<void> saveChapterScroll(String id, int chapter, double top) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('local_epub_scroll_${id}_$chapter', top);
  }

  Future<double> chapterScroll(String id, int chapter) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('local_epub_scroll_${id}_$chapter') ?? 0;
  }

  /// Bytes used by every local book on disk.
  Future<int> diskUsageBytes() async {
    final dir = Directory(await root());
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
