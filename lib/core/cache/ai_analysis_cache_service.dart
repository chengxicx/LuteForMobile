import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

import 'cache_logger.dart';

/// One cached AI analysis payload (sentence translation or grammar panel).
///
/// Stored as a plain JSON string in a `Box<String>`: no Hive adapter and no
/// codegen.  `result` keeps the server contract field names, so reading an
/// entry back is just `XxxResult.fromJson(entry.result!)`.
class AiAnalysisCacheEntry {
  final int timestamp;
  final int sizeInBytes;
  final Map<String, dynamic>? result;
  final String? fallbackText;
  final String? provider;
  final String? model;

  /// 这条是「离线整本下载」预取写进来的：属于用户显式下载的资产，体积
  /// 淘汰时不动它（见 [AiAnalysisCacheService._enforceSizeLimits]）。
  final bool pinned;

  /// 最近一次与服务端比对过的时间（epoch ms）。只用于限频 —— 每句每天
  /// 最多比对一次，避免每次开面板都白跑一趟网络。
  final int? verifiedAt;

  /// 这条结果是在读哪本书时产生的。
  ///
  /// 缓存以（语言, 句子）为身份，一句话可能出现在多本书里，所以是集合。
  /// 离线整本下载靠它把「这本书的」解释认出来 pin 住并给出覆盖条数；
  /// 升级前写入的条目没有这个字段，由离线下载按句子缓存回填。
  final List<int>? bookIds;

  const AiAnalysisCacheEntry({
    required this.timestamp,
    required this.sizeInBytes,
    this.result,
    this.fallbackText,
    this.provider,
    this.model,
    this.pinned = false,
    this.verifiedAt,
    this.bookIds,
  });

  /// Tolerant decode: corrupt or future-version data returns null instead of
  /// throwing, mirroring how the other caches treat unreadable entries.
  static AiAnalysisCacheEntry? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final ts = json['ts'];
      if (ts is! int) return null;
      final result = json['result'];
      return AiAnalysisCacheEntry(
        timestamp: ts,
        sizeInBytes: json['sz'] is int ? json['sz'] as int : raw.length,
        result: result is Map ? Map<String, dynamic>.from(result) : null,
        fallbackText: json['fallback'] is String ? json['fallback'] as String : null,
        provider: json['provider'] is String ? json['provider'] as String : null,
        model: json['model'] is String ? json['model'] as String : null,
        pinned: json['pinned'] == true,
        verifiedAt: json['verifiedAt'] is int ? json['verifiedAt'] as int : null,
        bookIds: (json['books'] is List)
            ? (json['books'] as List)
                .whereType<int>()
                .toList(growable: false)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  AiAnalysisCacheEntry copyWith({
    int? timestamp,
    int? sizeInBytes,
    int? verifiedAt,
    bool? pinned,
    List<int>? bookIds,
  }) {
    return AiAnalysisCacheEntry(
      timestamp: timestamp ?? this.timestamp,
      sizeInBytes: sizeInBytes ?? this.sizeInBytes,
      result: result,
      fallbackText: fallbackText,
      provider: provider,
      model: model,
      pinned: pinned ?? this.pinned,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      bookIds: bookIds ?? this.bookIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'v': 1,
      'ts': timestamp,
      'sz': sizeInBytes,
      if (result != null) 'result': result,
      if (fallbackText != null) 'fallback': fallbackText,
      if (provider != null) 'provider': provider,
      if (model != null) 'model': model,
      if (pinned) 'pinned': true,
      if (verifiedAt != null) 'verifiedAt': verifiedAt,
      if (bookIds != null && bookIds!.isNotEmpty) 'books': bookIds,
    };
  }
}

/// Persistent cache for AI panel results, shared by the sentence translation
/// and grammar analysis notifiers (one instance per Hive box name).
///
/// The server answers `/ai/translate` and `/ai/grammar/analyze` with its own
/// cache, but a client-side copy is what makes a re-opened panel instant and
/// lets prefetch fill results in before they are ever requested.  Errors are
/// never cached -- callers simply don't [saveToCache] on failure.
///
/// 保留策略（2026-11 用户定）：**永久保留，只按体积淘汰**。
///
/// - 没有 TTL：句子解释不会因为「放了两周」而失效 —— 用户重读一本书时
///   仍然免一次 LLM 调用。服务端结果若真的变了，由面板侧的比对提示刷新
///   （见 `sentence_ai_provider`），而不是把整份缓存悄悄丢掉。
/// - 体积上限只管**非 pinned** 条目：超过 [maxCacheSizeBytes] 时按最旧
///   淘汰到 80%（一次淘汰留出回旋余量，避免每次写入都触发全表扫描式淘汰）。
/// - **pinned** 条目（离线整本下载预取的解释）永不淘汰：那是用户显式下载的
///   资产，容量由下载入口在下载前告知并计入离线包体积。
class AiAnalysisCacheService {
  final String _boxName;
  final int _maxCacheSizeBytes;

  Box<String>? _box;
  bool _isInitialized = false;

  /// [maxCacheSizeBytes] 存在是为了测试能把它缩小；生产默认 100MB，
  /// 与页面缓存（100MB）/ 句子缓存（100MB）同一量级。
  AiAnalysisCacheService({required String boxName, int? maxCacheSizeBytes})
    : _boxName = boxName,
      _maxCacheSizeBytes = maxCacheSizeBytes ?? 100 * 1024 * 1024;

  /// The Hive box backing this cache; tests use it to plant raw entries.
  String get boxName => _boxName;

  /// Cache key for an analysis request.  Results depend only on the sentence
  /// text and language, so the hash of both is the identity across sessions
  /// and books.
  static String cacheKey(int langId, String sentence) {
    return sha1.convert(utf8.encode('$langId|$sentence')).toString();
  }

  /// 内容指纹：用来判断「服务端这次给的」和「本地存的」是不是同一份结果。
  ///
  /// 服务端没有暴露版本号/updated_at（改服务端要另发一轮），而结果本身
  /// 就是它现在的答案 —— 把结构规范排序后取 sha1 是同等可靠的信号：
  /// provider 换模型、服务端缓存被清后重算，内容一变指纹就变。
  static String payloadHash(
    Map<String, dynamic>? result,
    String? fallbackText,
  ) {
    final canonical = _canonicalJson(
      <String, dynamic>{
        if (result != null) 'result': result,
        if (fallbackText != null && fallbackText.isNotEmpty)
          'fallback': fallbackText,
      },
    );
    return sha1.convert(utf8.encode(canonical)).toString();
  }

  /// JSON 里对象的键序不保证稳定（不同序列化路径会换顺序），先按键名递归
  /// 排序再编码，避免「内容一样、指纹不同」的误报。
  static String _canonicalJson(Object? value) {
    return jsonEncode(_sorted(value));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sorted(value[k])};
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }

  Future<void> initialize() async {
    try {
      if (!_isInitialized) {
        _box = await Hive.openBox<String>(_boxName);

        await _enforceSizeLimits();

        _isInitialized = true;
        CacheLogger.log('$_boxName initialized (entries: ${_box!.length})');
      }
    } catch (e) {
      CacheLogger.logError('$_boxName.initialize', e);
      rethrow;
    }
  }

  Future<AiAnalysisCacheEntry?> getFromCache(String key) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }
      if (_box == null) {
        CacheLogger.log('$_boxName not initialized');
        return null;
      }

      final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
      if (entry == null) {
        CacheLogger.log('$_boxName MISS: key=$key (unreadable)');
        return null;
      }

      CacheLogger.log('$_boxName HIT: key=$key');
      return entry;
    } catch (e) {
      CacheLogger.logError('$_boxName.getFromCache', e);
      return null;
    }
  }

  /// Stores a successful payload.  Skips silently when there is nothing to
  /// cache (both [result] and [fallbackText] absent).
  ///
  /// [pinned] marks an entry written by the offline full-book download: it is
  /// never evicted by the size cap.
  ///
  /// [bookId] 记下这条结果是读哪本书时产生的（离线下载据此给出覆盖条数）。
  /// 覆盖写入时保留原条目的 pinned 与 bookIds：用户点刷新会重写内容，但
  /// 不该因此把一条已 pin 的离线资产变回可淘汰。
  Future<bool> saveToCache({
    required String key,
    Map<String, dynamic>? result,
    String? fallbackText,
    String? provider,
    String? model,
    bool pinned = false,
    int? bookId,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }
      if (_box == null) {
        CacheLogger.log('$_boxName not initialized');
        return false;
      }
      if (result == null && (fallbackText == null || fallbackText.isEmpty)) {
        return false;
      }

      // 内容刚来自服务端，等同于刚比对过 —— 记下 verifiedAt，别的面板
      // 打开时不必再为它跑一次比对。
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final existing = AiAnalysisCacheEntry.parse(_box!.get(key));
      final books = <int>{
        ...?existing?.bookIds,
        if (bookId != null) bookId,
      }.toList(growable: false);
      final entry = AiAnalysisCacheEntry(
        timestamp: timestamp,
        sizeInBytes: 0,
        result: result,
        fallbackText: fallbackText,
        provider: provider,
        model: model,
        pinned: pinned || (existing?.pinned ?? false),
        verifiedAt: timestamp,
        bookIds: books.isEmpty ? null : books,
      );

      await _putMeasured(key, entry);
      await _enforceSizeLimits();

      CacheLogger.log('$_boxName SAVE: key=$key');
      return true;
    } catch (e) {
      CacheLogger.logError('$_boxName.saveToCache', e);
      return false;
    }
  }

  /// 把 [bookId] 这本书**已有的**解释标成 pinned，返回归到这本书的条目数
  /// —— 就是离线下载结果里「已包含 N 条解释」的 N。全程不发任何 AI 请求。
  ///
  /// 两个来源：条目自己记着 bookId；或者条目是升级前写的（没有 bookId），
  /// 但它的句子出现在 [legacyKeys] 里 —— 那批顺手补上 bookId，以后就不必
  /// 再依赖句子缓存（句子缓存有 14 天 TTL，AI 缓存是永久的）。
  Future<int> pinForBook({
    required int bookId,
    Iterable<String> legacyKeys = const [],
  }) async {
    if (!_isInitialized) await initialize();
    final box = _box;
    if (box == null) return 0;

    final legacy = legacyKeys.toSet();
    final keys = box.keys.toList(growable: false);
    var matched = 0;
    for (final key in keys) {
      final entry = AiAnalysisCacheEntry.parse(box.get(key));
      if (entry == null) continue;
      final owned = entry.bookIds?.contains(bookId) ?? false;
      if (!owned && !legacy.contains(key)) continue;
      matched++;
      if (owned && entry.pinned) continue;
      await _putMeasured(
        key,
        entry.copyWith(
          pinned: true,
          bookIds: <int>{...?entry.bookIds, bookId}.toList(growable: false),
        ),
      );
    }
    CacheLogger.log('$_boxName PIN book=$bookId entries=$matched');
    return matched;
  }

  /// 已随包保留（pinned）且归到某本书的解释条数，只读不写盘。
  /// 离线下载入口用它显示覆盖范围：只有 pin 过的才会在离线包里留着，
  /// 普通缓存条目随时可能被体积淘汰，不能算进「已包含」。
  Future<int> countForBook(int bookId) async {
    if (!_isInitialized) await initialize();
    final box = _box;
    if (box == null) return 0;
    var count = 0;
    for (final key in box.keys.toList(growable: false)) {
      final entry = AiAnalysisCacheEntry.parse(box.get(key));
      if (entry == null || !entry.pinned) continue;
      if (entry.bookIds?.contains(bookId) ?? false) count++;
    }
    return count;
  }

  /// 只记「已与服务端比对过」，不动内容。
  ///
  /// [verifiedAt] 用于限频：一句一天最多比对一次。内容要换由调用方显式
  /// [saveToCache]（用户点刷新时才会发生）。
  Future<void> markVerified(String key, {int? verifiedAt}) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }
      final raw = _box?.get(key);
      final entry = AiAnalysisCacheEntry.parse(raw);
      if (entry == null) return;
      await _putMeasured(
        key,
        entry.copyWith(
          verifiedAt: verifiedAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      CacheLogger.logError('$_boxName.markVerified', e);
    }
  }

  /// 把条目编码后写回，并回填真实体积。
  Future<void> _putMeasured(String key, AiAnalysisCacheEntry entry) async {
    // `sizeInBytes` 本身在 JSON 里，先按 0 测一次再按真实值写一次
    // （差几个字节不影响统计）。
    final size = utf8.encode(jsonEncode(entry.toJson())).length;
    final sized = entry.copyWith(sizeInBytes: size);
    await _box!.put(key, jsonEncode(sized.toJson()));
  }

  Future<bool> clearAllCache() async {
    try {
      if (!_isInitialized) {
        await initialize();
      }
      if (_box == null) {
        CacheLogger.log('$_boxName not initialized');
        return false;
      }

      await _box!.clear();
      CacheLogger.logClear(_boxName);
      return true;
    } catch (e) {
      CacheLogger.logError('$_boxName.clearAllCache', e);
      return false;
    }
  }

  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      if (!_isInitialized) {
        await initialize();
      }
      if (_box == null) {
        return {'error': 'Cache not initialized'};
      }

      int totalSize = 0;
      int pinnedSize = 0;
      int pinnedEntries = 0;

      for (final key in _box!.keys) {
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry == null) continue;
        totalSize += entry.sizeInBytes;
        if (entry.pinned) {
          pinnedSize += entry.sizeInBytes;
          pinnedEntries++;
        }
      }

      return {
        'totalEntries': _box!.length,
        'totalSizeBytes': totalSize,
        'totalSizeMB': totalSize / (1024 * 1024),
        'pinnedEntries': pinnedEntries,
        'pinnedSizeMB': pinnedSize / (1024 * 1024),
        'evictableSizeMB': (totalSize - pinnedSize) / (1024 * 1024),
        'maxSizeMB': _maxCacheSizeBytes / (1024 * 1024),
        'isOverSizeLimit': totalSize - pinnedSize > _maxCacheSizeBytes,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 只按体积淘汰，且只动非 pinned 条目。
  ///
  /// 淘汰到 80% 而不是刚好到上限：上限附近的每次写入都淘汰一条的话，
  /// 每条新结果都要触发一遍全表扫描，反而更贵。
  Future<void> _enforceSizeLimits() async {
    try {
      if (_box == null) return;

      int evictableSize = 0;
      final evictable = <String, int>{};

      for (final key in _box!.keys) {
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry == null) continue;
        if (entry.pinned) continue;
        evictableSize += entry.sizeInBytes;
        evictable[key as String] = entry.timestamp;
      }

      if (evictableSize <= _maxCacheSizeBytes) return;

      final target = _maxCacheSizeBytes * 8 ~/ 10;
      final keysByAge = evictable.keys.toList()
        ..sort((a, b) => evictable[a]!.compareTo(evictable[b]!));

      for (final key in keysByAge) {
        if (evictableSize <= target) break;
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry != null) evictableSize -= entry.sizeInBytes;
        await _box!.delete(key);
      }
    } catch (e) {
      CacheLogger.logError('$_boxName.enforceSizeLimits', e);
    }
  }

  Future<void> close() async {
    try {
      if (_box != null && _box!.isOpen) {
        await _box!.close();
      }
      _isInitialized = false;
    } catch (e) {
      CacheLogger.logError('$_boxName.close', e);
    }
  }
}
