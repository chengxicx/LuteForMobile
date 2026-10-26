import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// 本机词典池里的一本词典。下载与导入都落到 `dict/pool/<filename>.db`，
/// **与语言无关**；每门语言各自"选用"池里的某一本（见
/// [DictRepository.selectDict]）。同一本词典可被多门语言同时选用
/// （例如同一本日汉词典既服务日语书籍也服务日语标签页）。
class PoolDict {
  const PoolDict({required this.filename, required this.sizeBytes});

  /// 池内文件名（唯一标识，也是下载目标名）。
  final String filename;

  /// 文件字节数。
  final int sizeBytes;

  double get sizeMb => sizeBytes / (1024 * 1024);
}

/// 本机词典池按文件名查询的结果。
///
/// 与 [DictRepository.lookupWithReading] 的 `String?` 不同，这里要把"本机
/// 没有这本词典"和"词典有、但没这个词条"分开：前者可以回落服务器渲染的
/// 词典页，后者不该再联网（联网也还是查不到）。
class PoolLookupResult {
  const PoolLookupResult({required this.available, this.gloss});

  /// 本机池里有这本词典（能离线回答，包括"查不到"）。
  final bool available;

  /// 命中的释义；null = 没这个词条。
  final String? gloss;

  bool get hit => gloss != null;
}

/// 本地词典（阶段 3）：SQLite 两表结构（terms/entries），来源两种——
///  1. 从服务器词典池选一本下载（GET /dict/status 列表 → 静态地址下载，
///     见 ServerDictionary.urlFor）；
///  2. 在设备上直接**导入 .mdx 文件**（纯 Dart MDX 解析器，本地转换）。
///
/// **下载/导入与语言解耦**：一律落到本机词典池 `dict/pool/<filename>.db`，
/// 一本词典只存一份；之后每门语言在自己的设置里"选用"池内词典
/// （SharedPreferences `dict_for_lang_<langId>` = 池内文件名）。误下载一本
/// 词典不再污染任何语言，也不需要为另一门语言重新下载同一本。
///
/// 兼容旧版"按语言分库"时代：升级前下载/导入生成的 `active_<langId>.db`
/// 会在设置页打开时被**收养**进池（改名 `legacy_lang_<langId>.db` 并设为
/// 该语言的选用词典，见 [adoptLegacyPerLangDicts]），行为连续；更早的
/// 单词典时代共享库（`active.db` / `ja_zh_shogakukan_v2.db`，仓库层不知
/// 道它属于哪门语言）不迁移，作为**查询回落**——但它们是日汉词典，只有
/// 日语书才回落（见 [lookupWithReading] 的 languageName 参数）；其他语言
/// 未选用词典时如实返回"未安装"，而不是静默查出日文词条。
///
/// 查询链：词条原文 → 读音 → 去掉开头的敬语前缀（お/ご）。词典键多数是
/// 假名读音（日汉词典典型结构），活用形还原（楽しかっ→たのしい）待做。
class DictRepository {
  DictRepository();

  /// 各语言"选用词典"的持久化 key。
  static String selectionKey(int langId) => 'dict_for_lang_$langId';

  /// 导入 .mdx 时生成池内文件名：取 basename 去扩展名，洗掉路径/控制
  /// 字符（保留中日韩文件名），加 `.db`。
  static String poolFileNameForMdx(String mdxPath) {
    var base = p.basename(mdxPath);
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    final cleaned = base
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+$'), '');
    final bare = cleaned.trim();
    // 全被洗掉（或只剩下划线）时给个固定名，别生成 '_.db' 这种。
    final name = bare.replaceAll('_', '').isEmpty ? 'imported' : bare;
    final capped = name.length > 80 ? name.substring(0, 80) : name;
    return '$capped.db';
  }

  /// 旧版"按语言分库"时代的激活库（兼容：查询回落用）。
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

  /// 本机词典池目录 `dict/pool/`。
  Future<Directory> _poolDir() async {
    final dir = await _dictDir();
    final pool = Directory(p.join(dir.path, 'pool'));
    if (!pool.existsSync()) pool.createSync(recursive: true);
    return pool;
  }

  Future<File> _activeFile(int langId) async =>
      File(p.join((await _dictDir()).path, activeFileName(langId)));

  Future<File?> _legacyFile() async {
    final file = File(p.join((await _dictDir()).path, _legacyName));
    return file.existsSync() ? file : null;
  }

  Future<File> _poolFile(String filename) async =>
      File(p.join((await _poolDir()).path, p.basename(filename)));

  // ---------------------------------------------------------------- 词典池

  /// 池内全部词典（按文件名排序）。空列表 = 一本都没下载/导入。
  Future<List<PoolDict>> listPool() async {
    final dir = await _poolDir();
    final list = <PoolDict>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.db')) continue;
      list.add(PoolDict(
        filename: p.basename(entity.path),
        sizeBytes: entity.lengthSync(),
      ));
    }
    list.sort((a, b) => a.filename.compareTo(b.filename));
    return list;
  }

  /// 从 URL 下载已转换的词典库，落到本机词典池 `pool/<filename>.db`。
  /// **不绑定任何语言**——下载完成后由用户在设置里为各门语言选用。
  /// 写成临时文件再原子改名覆盖；失败清掉半截文件。
  Future<bool> downloadToPool(
    String url, {
    required String filename,
    void Function(int received, int total)? onProgress,
  }) async {
    final name = p.basename(filename);
    if (name.isEmpty || name == '.' || name == '..') return false;
    File? tmp;
    try {
      final dir = await _poolDir();
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
      final target = File(p.join(dir.path, name));
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
      _invalidate();
      return true;
    } catch (e) {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  /// 在设备上导入 .mdx：解析 → 去重转换 → 写临时库 → 原子改名进池。
  /// 池内文件名由 [poolFileNameForMdx] 派生；同名即覆盖（重新导入=更新）。
  /// [onProgress] 收到已处理的词条数（总量解析前未知）。
  ///
  /// 任何失败都先删掉半截的 `import.tmp` 再返回，绝不留下一个能被打开的
  /// 残缺库——否则下次 lookup 会打开它并给出乱七八糟的结果。
  Future<ImportResult> importMdxToPool(
    String mdxPath, {
    void Function(int processed)? onProgress,
  }) async {
    File? tmp;
    Database? db;
    try {
      final reader = MdxReader.fromFile(mdxPath);

      final dir = await _poolDir();
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
      final target = await _poolFile(poolFileNameForMdx(mdxPath));
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
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

  /// 从池里删除一本词典（文件移除，并清掉所有语言里指向它的选用）。
  /// 返回是否真的删掉了文件。删除后受影响语言回落到旧版共享库（若有）。
  Future<bool> deletePoolDict(String filename) async {
    final file = await _poolFile(filename);
    var deleted = false;
    if (file.existsSync()) {
      file.deleteSync();
      deleted = true;
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!RegExp(r'^dict_for_lang_\d+$').hasMatch(key)) continue;
      if (prefs.getString(key) == filename) await prefs.remove(key);
    }
    _invalidate();
    return deleted;
  }

  // ------------------------------------------------------- 语言 ↔ 词典选用

  /// [langId] 当前选用的池内文件名；没选过返回 null。
  /// 不校验文件是否存在（调用方与查询层都会兜底）。
  Future<String?> selectedDict(int langId) async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(selectionKey(langId));
    return (name == null || name.isEmpty) ? null : name;
  }

  /// 为 [langId] 选用池内词典；传 null = 清除选用（回落旧版库）。
  /// 选用的文件必须存在于池中，否则抛 [ArgumentError]。
  Future<void> selectDict(int langId, String? filename) async {
    final prefs = await SharedPreferences.getInstance();
    if (filename == null || filename.isEmpty) {
      await prefs.remove(selectionKey(langId));
      _invalidate();
      return;
    }
    final file = await _poolFile(filename);
    if (!file.existsSync()) {
      throw ArgumentError('词典不在本机词典库：$filename');
    }
    await prefs.setString(selectionKey(langId), p.basename(filename));
    _invalidate();
  }

  /// 全部语言的选用关系（langId → 池内文件名），供设置页摘要用。
  Future<Map<int, String>> selectionMap() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <int, String>{};
    for (final key in prefs.getKeys()) {
      final m = RegExp(r'^dict_for_lang_(\d+)$').firstMatch(key);
      if (m == null) continue;
      final name = prefs.getString(key);
      if (name == null || name.isEmpty) continue;
      result[int.parse(m.group(1)!)] = name;
    }
    return result;
  }

  /// 收养旧版"按语言分库"时代的 `active_<langId>.db`：移进池（改名
  /// `legacy_lang_<langId>.db`）并设为该语言的选用词典（尚未选过时）。
  /// 幂等，可重复调用；旧文件已被收养后再次调用是空操作。
  Future<void> adoptLegacyPerLangDicts() async {
    final dir = await _dictDir();
    final reg = RegExp(r'^active_(\d+)\.db$');
    final prefs = await SharedPreferences.getInstance();
    var moved = false;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final m = reg.firstMatch(p.basename(entity.path));
      if (m == null) continue;
      final langId = int.parse(m.group(1)!);
      final sel = prefs.getString(selectionKey(langId));
      if (sel != null && sel.isNotEmpty) {
        // 该语言已选用池内词典，旧文件纯属占地方，直接清掉。
        entity.deleteSync();
        continue;
      }
      final target = await _poolFile('legacy_lang_$langId.db');
      if (target.existsSync()) {
        // 池里已有同名（重复收养的残留）：直接选它、删旧文件。
        await prefs.setString(selectionKey(langId), p.basename(target.path));
        entity.deleteSync();
        moved = true;
        continue;
      }
      entity.renameSync(target.path);
      await prefs.setString(selectionKey(langId), p.basename(target.path));
      moved = true;
    }
    if (moved) _invalidate();
  }

  // ------------------------------------------------------------- 安装状态

  /// 某语言是否有可用词典（选用了池内词典，或还留着旧版 per-lang 库）。
  Future<bool> isInstalled(int langId) async {
    if (await selectedDict(langId) != null) return true;
    return (await _activeFile(langId)).existsSync();
  }

  /// 有可用词典的语言 id 列表（选用池词典的语言 ∪ 残留 per-lang 旧库）。
  Future<List<int>> installedLangIds() async {
    final ids = <int>{};
    final poolNames = (await listPool()).map((d) => d.filename).toSet();
    final selections = await selectionMap();
    selections.forEach((langId, name) {
      if (poolNames.contains(name)) ids.add(langId);
    });
    final dir = await _dictDir();
    final reg = RegExp(r'^active_(\d+)\.db$');
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final m = reg.firstMatch(p.basename(entity.path));
      if (m != null) ids.add(int.parse(m.group(1)!));
    }
    final list = ids.toList()..sort();
    return list;
  }

  /// 是否存在旧版单词典时代的共享库（查询回落的数据源）。
  Future<bool> hasLegacyDict() async {
    final dir = await _dictDir();
    if (File(p.join(dir.path, _legacySharedName)).existsSync()) return true;
    return (await _legacyFile()) != null;
  }

  // ----------------------------------------------------------------- 查询

  /// 与 web 端 `lute/dict/service.py: strip_duplicate_headword` 逐条对齐的
  /// Dart 版：词条释义以词典自己的词头开头（如
  /// `目覚まし時計【めざましどけい⑤】`），而卡片头部已经显示了查的词，
  /// 那一行就是纯重复——只在**整行**只复述了 [text]（词头 + 可选
  /// 【读音】注释 + 空白）时才删掉它。
  ///
  /// 首行是别的内容（通过读音查到的词条自己的词头、词性、释义本体）时
  /// 原样返回；词条只剩词头一行时也不删（否则什么都不剩）。
  static String? stripDuplicateHeadword(String? gloss, String? text) {
    if (gloss == null || gloss.isEmpty || text == null || text.isEmpty) {
      return gloss;
    }
    final lines = gloss.split('\n');
    // 比较前洗掉零宽空格并 trim：词典词头里常埋 \u200b 控制版式。
    const zwsp = '\u200b';
    final key = text.replaceAll(zwsp, '').trim();
    final first = lines.first.replaceAll(zwsp, '').trim();
    if (key.isEmpty || !first.startsWith(key)) return gloss;
    // 词头之后只允许空白与一段可选的【…】注释——注释里出现别的字
    // （【他動】之类）说明首行还承载信息，保留。
    final rest = RegExp(r'^\s*(?:【[^】]*】)?\s*$')
        .firstMatch(first.substring(key.length));
    if (rest == null) return gloss;
    final remainderHasContent = lines.skip(1).any((l) => l.trim().isNotEmpty);
    if (!remainderHasContent) return gloss;
    return lines.sublist(1).join('\n');
  }

  /// 按候选词链查询释义（已剥 HTML 的纯文本，带换行）。查不到返回 null。
  ///
  /// [langId] 决定查哪个语言的词典：该语言选用的池内词典 → 旧版 per-lang
  /// 库（见类注释）。langId 为 null（正文缺语言信息）时无法路由，直接返回
  /// null。
  ///
  /// 更早的共享时代旧库（active.db / ja_zh_shogakukan_v2.db）是**日汉**
  /// 词典：只有 [languageName] 是日语的书才回落它们——否则英文等语言没
  /// 选词典时会静默查出 テイク【take】 这种日文词条（见 2026-10-26 的
  /// 英文词典排查）。非日语没有词典就返回 null，显示"未选用词典"。
  Future<String?> lookupWithReading(
    String term,
    String? reading, {
    int? langId,
    String? languageName,
  }) async {
    if (langId == null) return null;
    final candidates = lookupCandidates(term, reading);
    if (candidates.isEmpty) return null;
    try {
      final db = await _openFor(langId, languageName: languageName);
      return await _queryTerm(db, candidates, term);
    } catch (e) {
      return null;
    }
  }

  /// 按**池内文件名**查询，与服务器 `/read/localdict/<db>/<text>` 的"按文件
  /// 查"一一对应。
  ///
  /// 这是词典面板离线可用的关键：设置页下载进本机池的那一本，查词时直接
  /// 命中本机 sqlite，不必再向服务器要渲染好的 HTML。返回值区分两件事——
  /// [PoolLookupResult.available] 为 false 表示"本机没有这本词典"（调用方
  /// 可以回落服务器），为 true 而 [PoolLookupResult.gloss] 是 null 表示
  /// "词典在、但没这个词条"（就该显示查不到，不该再联网）。
  Future<PoolLookupResult> lookupInPool({
    required String filename,
    required String term,
    String? reading,
  }) async {
    final name = p.basename(filename);
    if (!name.toLowerCase().endsWith('.db')) {
      return const PoolLookupResult(available: false);
    }
    File file;
    try {
      file = await _poolFile(name);
    } catch (_) {
      return const PoolLookupResult(available: false);
    }
    if (!file.existsSync()) return const PoolLookupResult(available: false);

    final candidates = lookupCandidates(term, reading);
    // 词洗完是空的（只剩零宽字符）：词典在，只是没法查。
    if (candidates.isEmpty) return const PoolLookupResult(available: true);
    try {
      final gloss = await _queryTerm(await _openPath(file), candidates, term);
      return PoolLookupResult(available: true, gloss: gloss);
    } catch (_) {
      // 池里文件打不开（下了一半、不是 app 词典格式）：当作没装，回落服务器。
      return const PoolLookupResult(available: false);
    }
  }

  /// 候选词逐个查 terms → entries；命中即返回剥掉重复词头后的释义。
  ///
  /// 与 web 阅读页同一规则：卡片头部已显示所查的词，释义开头那行纯复述
  /// 词头的（含【读音】注释）删掉。以查询词 [term] 为准，与命中用的候选
  /// 词无关（读音命中的词条首行不匹配即原样保留）。
  Future<String?> _queryTerm(
    Database db,
    List<String> candidates,
    String term,
  ) async {
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
      if (def is! String || def.isEmpty) return null;
      return stripDuplicateHeadword(def, term);
    }
    return null;
  }

  /// 解析 [langId] 应使用的词典文件：该语言选用的池内词典 → 旧版 per-lang
  /// 库。都没有则返回 null（词典未安装）。
  ///
  /// 共享时代旧库（active.db / ja_zh_shogakukan_v2.db）只在
  /// [languageName] 为日语时才作最后回落（见 lookupWithReading）。
  Future<File?> _resolveDictFile(int langId, {String? languageName}) async {
    final prefs = await SharedPreferences.getInstance();
    final sel = prefs.getString(selectionKey(langId));
    if (sel != null && sel.isNotEmpty) {
      final picked = await _poolFile(sel);
      if (picked.existsSync()) return picked;
    }
    final perLang = await _activeFile(langId);
    if (perLang.existsSync()) return perLang;
    if (!legacySharedServes(languageName)) return null;
    final dir = await _dictDir();
    final shared = File(p.join(dir.path, _legacySharedName));
    if (shared.existsSync()) return shared;
    return _legacyFile();
  }

  /// 共享时代旧库（active.db / ja_zh_shogakukan_v2.db）是日汉词典，
  /// 只服务日语书：其他语言未选用词典时不能静默回落它们。
  static bool legacySharedServes(String? languageName) {
    final name = (languageName ?? '').trim().toLowerCase();
    return name.contains('jap') || name.contains('日本語') || name.contains('日语');
  }

  /// 单槽打开缓存：阅读一次只查一本书的语言，同路径复用连接，跨语言
  /// 切换（阅读中不会发生）时重开一次。
  Future<Database> _openFor(int langId, {String? languageName}) async {
    final file = await _resolveDictFile(langId, languageName: languageName);
    if (file == null) throw const FileSystemException('词典未下载');
    return _openPath(file);
  }

  /// 按文件打开（走同一个单槽缓存，按路径判重）。
  Future<Database> _openPath(File file) async {
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

  /// 失败收尾：关掉可能还开着的临时库，删掉半截文件。
  Future<void> _discard(Database? db, File? tmp) async {
    try {
      if (db != null) await db.close();
    } catch (_) {}
    try {
      if (tmp != null && tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }

  /// 词典里绝不会出现的零宽字符：双词选中拼词时会插入 U+200B 当分隔符，
  /// 词头本身也可能埋 U+200B 控制版式（MOJi 的读法注释里就有）。带着它们
  /// 查词必然是"有词条却查不到"，所以候选词先洗一遍。
  static final RegExp _zeroWidth = RegExp('[\u200b\u200c\u200d\ufeff]');

  /// 洗掉零宽字符并 trim（词条显示仍用原文，只在本仓库的查询链里洗）。
  static String normalizeWord(String word) =>
      word.replaceAll(_zeroWidth, '').trim();

  /// 查询候选词：词条原文 → 读音 → 去掉开头的敬语前缀（お/ご）。
  /// 词典键是假名读音且不带敬语（おひさしぶり 在键里是 ひさしぶり）。
  static List<String> lookupCandidates(String term, String? reading) {
    final list = <String>[];
    void add(String word) {
      final w = normalizeWord(word);
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
