import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'mdx_reader.dart';

/// 导入结果。比 `bool` 多带一条给用户看的理由——导入失败的原因差别很大
/// （"这本词典需要密码" vs "这个文件坏了" vs "选错了文件"），只回一个
/// false 会让三种情况显示同一句没用的提示。
class ImportResult {
  const ImportResult.ok(this.entries)
      : status = ImportStatus.ok,
        message = '';
  const ImportResult.unsupported(String this.message)
      : status = ImportStatus.unsupported,
        entries = 0;
  const ImportResult.corrupt(String this.message)
      : status = ImportStatus.corrupt,
        entries = 0;
  const ImportResult.empty()
      : status = ImportStatus.empty,
        entries = 0,
        message = '这个文件里没有解析出任何词条';
  const ImportResult.ioError(String this.message)
      : status = ImportStatus.ioError,
        entries = 0;

  final ImportStatus status;

  /// 已写入的词条数（仅 [ImportStatus.ok] 时有意义）。
  final int entries;

  /// 面向用户的失败原因；成功时为空串。
  final String message;

  bool get ok => status == ImportStatus.ok;
}

enum ImportStatus {
  ok,

  /// 文件是 MDX，但用了本解析器不支持的特性（GBK、v3 记录区、regcode 加密…）。
  unsupported,

  /// 文件损坏、被截断，或根本不是 MDX。
  corrupt,

  /// 解析通了但一条词条都没有（空词典/词头全为空）。
  empty,

  /// 读写失败（磁盘满、文件被删、数据库打不开…）。
  ioError,
}

/// 本地词典（阶段 3）：SQLite 两表结构（terms/entries），来源两种——
///  1. 从服务器词典池选一本下载（GET /dict/status 列表 → 静态地址下载，
///     见 ServerDictionary.urlFor）；
///  2. 在设备上直接**导入 .mdx 文件**（纯 Dart MDX 解析器，本地转换）。
///
/// 词典按语言分库：激活库固定为 support/dict/`active_<langId>.db`，下载/导入
/// 都必须带 langId，写成临时文件再原子改名覆盖对应语言的库。查询也按 langId
/// 路由——读日语书查日语库，读韩语书查韩语库，互不干扰。
///
/// 兼容旧版单词典时代：用户升级前装好的 active.db（及更早的
/// ja_zh_shogakukan_v2.db）不迁移（仓库层无法知道它是哪门语言），而是作为
/// **查询回落**：某语言没有自己的 `active_<langId>.db` 时回落到旧库。行为与
/// 升级前完全一致；一旦给该语言下载/导入了专属词典，即优先生效。
///
/// 查询链：词条原文 → 读音 → 去掉开头的敬语前缀（お/ご）。词典键多数是
/// 假名读音（日汉词典典型结构），活用形还原（楽しかっ→たのしい）待做。
class DictRepository {
  DictRepository();

  /// 各语言的激活词典库（下载与导入都落到这里）。
  static String activeFileName(int langId) => 'active_$langId.db';

  /// 旧版单词典时代的激活库（兼容：查询回落用）。
  static const String _legacySharedName = 'active.db';

  /// 更早版本直接下载的文件名（兼容：查询回落用）。
  static const String _legacyName = 'ja_zh_shogakukan_v2.db';

  final Dio _dio = Dio();

  Database? _db;
  String? _openedPath;
  Future<Database>? _opening;
  String? _openingPath;

  Future<Directory> _dictDir() async {
    final dir = await getApplicationSupportDirectory();
    final dictDir = Directory(p.join(dir.path, 'dict'));
    if (!dictDir.existsSync()) dictDir.createSync(recursive: true);
    return dictDir;
  }

  Future<File> _activeFile(int langId) async =>
      File(p.join((await _dictDir()).path, activeFileName(langId)));

  Future<File?> _legacyFile() async {
    final file = File(p.join((await _dictDir()).path, _legacyName));
    return file.existsSync() ? file : null;
  }

  /// 某语言的专属词典是否已就绪（严格判定：只看 `active_<langId>.db`，
  /// 不含旧版回落库——否则装了日语词典后所有语言都显示"已就绪"，
  /// 用户分不清哪门语言有自己的词典）。
  Future<bool> isInstalled(int langId) async =>
      (await _activeFile(langId)).existsSync();

  /// 是否存在旧版单词典时代的库（查询回落的数据源）。
  Future<bool> hasLegacyDict() async {
    final dir = await _dictDir();
    if (File(p.join(dir.path, _legacySharedName)).existsSync()) return true;
    return (await _legacyFile()) != null;
  }

  /// 已安装专属词典的语言列表（扫 dict 目录里的 `active_<langId>.db`）。
  Future<List<int>> installedLangIds() async {
    final dir = await _dictDir();
    final reg = RegExp(r'^active_(\d+)\.db$');
    final ids = <int>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final m = reg.firstMatch(p.basename(entity.path));
      if (m != null) ids.add(int.parse(m.group(1)!));
    }
    ids.sort();
    return ids;
  }

  /// 从 URL 下载已转换的词典库，落到 [langId] 语言的激活库。
  /// 写成临时文件再原子改名覆盖；失败清掉半截文件。
  Future<bool> download(
    String url, {
    required int langId,
    void Function(int received, int total)? onProgress,
  }) async {
    File? tmp;
    try {
      final dir = await _dictDir();
      tmp = File(p.join(dir.path, 'download.tmp'));
      await _dio.download(
        url,
        tmp.path,
        onReceiveProgress: onProgress,
        options: Options(
          // 一次性大文件下载，失败重下即可，不进离线队列。
          extra: {'noQueue': true},
        ),
      );
      if (!tmp.existsSync() || tmp.lengthSync() == 0) {
        if (tmp.existsSync()) tmp.deleteSync();
        return false;
      }
      final active = await _activeFile(langId);
      if (active.existsSync()) active.deleteSync();
      tmp.renameSync(active.path);
      _invalidate();
      return true;
    } catch (e) {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  /// 在设备上导入 .mdx：解析 → 去重转换 → 写临时库 → 原子改名激活。
  /// 落到 [langId] 语言的激活库。[onProgress] 收到已处理的词条数
  /// （总量解析前未知）。
  ///
  /// 任何失败都先删掉半截的 `import.tmp` 再返回，绝不留下一个能被打开的
  /// 残缺库——否则下次 lookup 会打开它并给出乱七八糟的结果。
  Future<ImportResult> importMdx(
    String mdxPath, {
    required int langId,
    void Function(int processed)? onProgress,
  }) async {
    File? tmp;
    Database? db;
    try {
      final reader = MdxReader.fromFile(mdxPath);

      final dir = await _dictDir();
      tmp = File(p.join(dir.path, 'import.tmp'));
      if (tmp.existsSync()) tmp.deleteSync();
      db = await openDatabase(tmp.path);
      await db.execute('CREATE TABLE entries(eid INTEGER PRIMARY KEY, def TEXT)');
      await db.execute('CREATE TABLE terms(word TEXT NOT NULL, eid INTEGER NOT NULL)');
      await db.execute('CREATE INDEX idx_terms ON terms(word)');

      final defHash = <String, int>{}; // 释义原文 → eid（精确去重）
      final seenWords = <String>{};
      final batchE = <List<Object?>>[];
      final batchT = <List<Object?>>[];
      var entries = 0;
      var processed = 0;
      var lastReport = 0;

      Future<void> flush() async {
        if (batchE.isNotEmpty) {
          await db!.writeEntryBatch(batchE, batchT);
          batchE.clear();
          batchT.clear();
        }
      }

      for (final entry in reader.entries()) {
        processed++;
        if (onProgress != null && processed - lastReport >= 2000) {
          lastReport = processed;
          onProgress(processed);
        }
        final word = MdxReader.cleanKey(entry.key);
        if (word.isEmpty || seenWords.contains(word)) continue;
        seenWords.add(word);
        final text = MdxReader.cleanDefinition(entry.value);
        if (text.isEmpty) continue;
        var eid = defHash[text];
        if (eid == null) {
          eid = defHash.length + 1;
          defHash[text] = eid;
          batchE.add([eid, text]);
          entries++;
        }
        batchT.add([word, eid]);
        if (batchT.length >= 4000) await flush();
      }
      await flush();
      await db.close();
      db = null;

      if (entries == 0) {
        if (tmp.existsSync()) tmp.deleteSync();
        return const ImportResult.empty();
      }
      final active = await _activeFile(langId);
      if (active.existsSync()) active.deleteSync();
      tmp.renameSync(active.path);
      _invalidate();
      return ImportResult.ok(entries);
    } on MdxUnsupportedException catch (e) {
      // 必须排在 FormatException 前面——它就是这个类的子类。
      await _discard(db, tmp);
      return ImportResult.unsupported(e.message);
    } on FormatException catch (e) {
      // 含 zlib/LZO 的"数据坏了"、头部校验不过、以及选错文件。
      await _discard(db, tmp);
      return ImportResult.corrupt(e.message);
    } on RangeError catch (e) {
      // 文件被截断时常见：偏移读到了文件尾之外。
      await _discard(db, tmp);
      return ImportResult.corrupt('MDX: 文件被截断或长度字段不一致（$e）');
    } catch (e) {
      await _discard(db, tmp);
      return ImportResult.ioError('$e');
    }
  }

  /// 失败收尾：关掉可能还开着的临时库，删掉半截文件。
  Future<void> _discard(Database? db, File? tmp) async {
    try {
      if (db != null) await db.close();
    } catch (_) {}
    try {
      if (tmp != null && tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }

  /// 按候选词链查询释义（已剥 HTML 的纯文本，带换行）。查不到返回 null。
  ///
  /// [langId] 决定查哪个语言的词典库；没有语言专属词典时回落到旧版
  /// 单典故时代的库（见类注释）。langId 为 null（正文缺语言信息）时
  /// 无法路由，直接返回 null。
  Future<String?> lookupWithReading(
    String term,
    String? reading, {
    int? langId,
  }) async {
    if (langId == null) return null;
    final candidates = lookupCandidates(term, reading);
    if (candidates.isEmpty) return null;
    try {
      final db = await _openFor(langId);
      for (final word in candidates) {
        final rows = await db.query(
          'terms',
          columns: ['eid'],
          where: 'word = ?',
          whereArgs: [word],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final defs = await db.query(
          'entries',
          columns: ['def'],
          where: 'eid = ?',
          whereArgs: [rows.first['eid']],
          limit: 1,
        );
        if (defs.isEmpty) continue;
        final def = defs.first['def'];
        return def is String && def.isNotEmpty ? def : null;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 解析 [langId] 应使用的词典文件：语言专属库 → 旧版共享库 → 更早的
  /// legacy 库。都没有则返回 null（词典未安装）。
  Future<File?> _resolveDictFile(int langId) async {
    final perLang = await _activeFile(langId);
    if (perLang.existsSync()) return perLang;
    final dir = await _dictDir();
    final shared = File(p.join(dir.path, _legacySharedName));
    if (shared.existsSync()) return shared;
    return _legacyFile();
  }

  /// 单槽打开缓存：阅读一次只查一本书的语言，同路径复用连接，跨语言
  /// 切换（阅读中不会发生）时重开一次。
  Future<Database> _openFor(int langId) async {
    final file = await _resolveDictFile(langId);
    if (file == null) throw const FileSystemException('词典未下载');
    final existing = _db;
    if (existing != null && _openedPath == file.path) {
      return Future.value(existing);
    }
    if (_opening != null && _openingPath == file.path) {
      return _opening!;
    }
    final opening = _openFile(file);
    _opening = opening;
    _openingPath = file.path;
    return opening;
  }

  Future<Database> _openFile(File file) async {
    try {
      final db = await openDatabase(file.path, readOnly: true);
      _db = db;
      _openedPath = file.path;
      return db;
    } catch (e) {
      _opening = null;
      rethrow;
    }
  }

  void _invalidate() {
    _opening = null;
    _openingPath = null;
    if (_db != null) {
      try {
        _db!.close();
      } catch (_) {}
    }
    _db = null;
    _openedPath = null;
  }

  /// 查询候选词：词条原文 → 读音 → 去掉开头的敬语前缀（お/ご）。
  /// 词典键是假名读音且不带敬语（おひさしぶり 在键里是 ひさしぶり）。
  static List<String> lookupCandidates(String term, String? reading) {
    final list = <String>[];
    void add(String word) {
      final w = word.trim();
      if (w.isNotEmpty && !list.contains(w)) list.add(w);
    }

    add(term);
    if (reading != null) {
      add(reading);
      final stripped = reading.replaceFirst(RegExp('^[おご]'), '');
      if (stripped != reading) add(stripped);
    }
    return list;
  }
}

extension _DictDbBatch on Database {
  /// sqflite 的 batch API 包装：词条/词头两表一批提交。
  Future<void> writeEntryBatch(
    List<List<Object?>> entriesRows,
    List<List<Object?>> termsRows,
  ) async {
    final b = batch();
    for (final row in entriesRows) {
      b.insert('entries', {
        'eid': row[0],
        'def': row[1],
      });
    }
    for (final row in termsRows) {
      b.insert('terms', {'word': row[0], 'eid': row[1]});
    }
    await b.commit(noResult: true);
  }
}

final dictRepositoryProvider = Provider<DictRepository>((ref) {
  return DictRepository();
});
