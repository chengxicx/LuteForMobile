import 'dart:collection';
import 'dart:convert';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/page_cache_entry.dart';
import '../../../core/cache/cache_logger.dart';

class PageCacheService {
  static const String _boxName = 'page_cache';
  static const Duration _ttl = Duration(days: 14);
  static const int _maxCacheSizeBytes = 100 * 1024 * 1024;
  static const String _cachePrefix = 'page_cache_';

  bool _isInitialized = false;

  /// 缓存总字节数，随写入 / 删除增量维护。
  ///
  /// 原来每次写入都要遍历整个 box 再逐个 get 来求和 —— 书缓存到几千页
  /// 后，每翻一页的缓存写入都要走一遍全表反序列化。现在只在初始化时
  /// 扫一次，之后靠 [_sizeIndexBytes] 与 [_lruKeys] 记账。
  int _sizeIndexBytes = 0;

  /// 最近使用的键，最旧的在前面。淘汰按它来，而不是按写入时间：
  /// 一本边读边缓存的书，翻回去看过的页不该比从没打开过的页先被丢掉。
  final LinkedHashSet<String> _lruKeys = LinkedHashSet<String>();

  PageCacheService();

  Future<void> _initialize() async {
    if (_isInitialized) return;

    try {
      final cacheDir = await getApplicationCacheDirectory();
      await Hive.initFlutter(cacheDir.path);

      final box = await Hive.openBox<PageCacheEntry>(_boxName);
      _buildSizeIndex(box);
      _isInitialized = true;
      CacheLogger.log('initialized');
    } catch (e) {
      CacheLogger.logError('initialize', e);
      _isInitialized = true;
    }
  }

  /// 一次全表扫描，建立总量与按写入时间排序的初始 LRU。
  void _buildSizeIndex(Box<PageCacheEntry> box) {
    final ordered = <(String, int)>[];
    var total = 0;
    for (final key in box.keys) {
      final entry = box.get(key);
      if (entry == null) continue;
      total += entry.sizeInBytes;
      ordered.add((key as String, entry.timestamp));
    }
    ordered.sort((a, b) => a.$2.compareTo(b.$2));
    _sizeIndexBytes = total;
    _lruKeys
      ..clear()
      ..addAll(ordered.map((e) => e.$1));
  }

  /// Cache hit: the key becomes the newest LRU position.
  void _touch(String key) {
    _lruKeys.remove(key);
    _lruKeys.add(key);
  }

  /// Forget a key that left the box (expired, removed, or evicted).
  void _forget(String key, int sizeInBytes) {
    _lruKeys.remove(key);
    _sizeIndexBytes -= sizeInBytes;
    if (_sizeIndexBytes < 0) _sizeIndexBytes = 0;
  }

  Future<Box<PageCacheEntry>> _getBox() async {
    await _initialize();
    return Hive.openBox<PageCacheEntry>(_boxName);
  }

  String _getCacheKey(int bookId, int pageNum) {
    return '$_cachePrefix${bookId}_$pageNum';
  }

  Future<PageCacheEntry?> getFromCache(int bookId, int pageNum) async {
    try {
      final box = await _getBox();
      final cacheKey = _getCacheKey(bookId, pageNum);
      final entry = box.get(cacheKey);

      if (entry == null) {
        CacheLogger.logMiss(_boxName, cacheKey.hashCode);
        return null;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - entry.timestamp;

      if (age > _ttl.inMilliseconds) {
        await box.delete(cacheKey);
        _forget(cacheKey, entry.sizeInBytes);
        CacheLogger.logMiss(_boxName, cacheKey.hashCode);
        return null;
      }

      // 读到的页是最新的 LRU 位置：下次淘汰从最久没读过的开始。
      _touch(cacheKey);
      CacheLogger.logHit(_boxName, cacheKey.hashCode);
      return entry;
    } catch (e) {
      CacheLogger.logError('getFromCache', e);
      return null;
    }
  }

  /// Gets just the metadata HTML from cache (without full entry)
  Future<String?> getMetadataFromCache(int bookId, int pageNum) async {
    final entry = await getFromCache(bookId, pageNum);
    return entry?.metadataHtml;
  }

  Future<void> saveToCache(
    int bookId,
    int pageNum,
    String metadataHtml,
    String pageTextHtml,
  ) async {
    try {
      final box = await _getBox();
      final cacheKey = _getCacheKey(bookId, pageNum);

      final metadataBytes = utf8.encode(metadataHtml).length;
      final pageTextBytes = utf8.encode(pageTextHtml).length;
      final sizeInBytes = metadataBytes + pageTextBytes;

      final entry = PageCacheEntry(
        metadataHtml: metadataHtml,
        pageTextHtml: pageTextHtml,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        sizeInBytes: sizeInBytes,
      );

      // 同一页重写：先把旧条目的大小从账上扣掉，再记新的。
      final previous = box.get(cacheKey);
      await box.put(cacheKey, entry);
      if (previous != null) _sizeIndexBytes -= previous.sizeInBytes;
      _sizeIndexBytes += sizeInBytes;
      _touch(cacheKey);
      // 先写后清：清理要按包含本页的总量判断，否则刚写进去的那页会把
      // 总量顶过上限而没人处理。
      await _enforceSizeLimit(box);
      CacheLogger.logSave(_boxName, cacheKey.hashCode);
    } catch (e) {
      CacheLogger.logError('saveToCache', e);
    }
  }

  Future<void> clearBookCache(int bookId) async {
    try {
      final box = await _getBox();
      final keysToDelete = <String>[];

      for (final key in box.keys) {
        final keyStr = key as String;
        if (keyStr.startsWith('$_cachePrefix${bookId}_')) {
          keysToDelete.add(keyStr);
        }
      }

      if (keysToDelete.isNotEmpty) {
        for (final key in keysToDelete) {
          _forget(key, box.get(key)?.sizeInBytes ?? 0);
        }
        await box.deleteAll(keysToDelete);
        CacheLogger.log(
          'cleared ${keysToDelete.length} entries for book $bookId',
        );
      }
    } catch (e) {
      CacheLogger.logError('clearBookCache', e);
    }
  }

  /// Drop a single page so the next read of it comes off the server.
  ///
  /// Used when an offline edit finally reaches the server: the cached copy
  /// still carries the pre-sync view, so keeping it would mean the corrected
  /// page only shows up after the entry expires -- and until then the reader
  /// would be looking at the very status the sync just replaced.
  Future<void> removeFromCache(int bookId, int pageNum) async {
    try {
      final box = await _getBox();
      final cacheKey = _getCacheKey(bookId, pageNum);
      final entry = box.get(cacheKey);
      await box.delete(cacheKey);
      _forget(cacheKey, entry?.sizeInBytes ?? 0);
      CacheLogger.logMiss(_boxName, cacheKey.hashCode);
    } catch (e) {
      CacheLogger.logError('removeFromCache', e);
    }
  }

  Future<void> clearAllCache() async {
    try {
      final box = await _getBox();
      await box.clear();
      _sizeIndexBytes = 0;
      _lruKeys.clear();
      CacheLogger.logClear(_boxName);
    } catch (e) {
      CacheLogger.logError('clearAllCache', e);
    }
  }

  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      final box = await _getBox();
      int totalSize = 0;
      int validEntries = 0;
      int expiredEntries = 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final entry in box.values) {
        totalSize += entry.sizeInBytes;
        final age = now - entry.timestamp;
        if (age > _ttl.inMilliseconds) {
          expiredEntries++;
        } else {
          validEntries++;
        }
      }

      return {
        'totalEntries': box.length,
        'validEntries': validEntries,
        'expiredEntries': expiredEntries,
        'totalSizeBytes': totalSize,
        'totalSizeMB': totalSize / (1024 * 1024),
        'maxSizeMB': _maxCacheSizeBytes / (1024 * 1024),
        'ttlDays': _ttl.inDays,
        'isOverSizeLimit': totalSize > _maxCacheSizeBytes,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 超阈值时按 LRU 批量淘汰，一直清到八成为止。
  ///
  /// 绝大多数写入在这里是 O(1)：总量没超就直接返回。清理一次清掉两成
  /// 余量，避免连续写入时每页都触发一轮删除。
  Future<void> _enforceSizeLimit(Box<PageCacheEntry> box) async {
    try {
      if (_sizeIndexBytes <= _maxCacheSizeBytes) return;

      final target = _maxCacheSizeBytes * 8 ~/ 10;
      while (_sizeIndexBytes > target && _lruKeys.isNotEmpty) {
        final oldestKey = _lruKeys.first;
        final oldestEntry = box.get(oldestKey);
        await box.delete(oldestKey);
        _forget(oldestKey, oldestEntry?.sizeInBytes ?? 0);
      }
    } catch (e) {
      CacheLogger.logError('enforceSizeLimit', e);
    }
  }
}
