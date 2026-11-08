import 'dart:collection';
import 'dart:convert';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/page_cache_entry.dart';
import '../../../core/cache/cache_logger.dart';

class PageCacheService {
  static const String _boxName = 'page_cache';
  static const String _pinBoxName = 'page_cache_pins';
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

  /// 用户显式下载过整本离线的书。
  ///
  /// 普通缓存是「可再生」的：14 天没人看就过期，超过 100MB 就按 LRU 淘汰。
  /// 但用户在详情弹窗里按下 Download 的那一刻，他得到的是「这本书以后断网
  /// 也能读」的承诺 —— 后台的 TTL/LRU 不能把这个承诺悄悄作废。pin 的书
  /// 因此既不过期、也不参与淘汰；取消或失败时才解除。
  final Set<int> _pinnedBookIds = <int>{};

  /// pin 集合的持久化载体（bookId -> true）。只存 id 不存页，
  /// 因为页里再塞一个 pinned 字段要在下载时逐页重写。
  Box<bool>? _pinBox;

  /// 被 pin 的页占的字节数。容量判定只看**可淘汰**的部分，
  /// 否则一本 100MB 的书会逼着每次写入都跑一遍全表淘汰扫描。
  int _pinnedBytes = 0;

  PageCacheService();

  Future<void> _initialize() async {
    if (_isInitialized) return;

    try {
      final cacheDir = await getApplicationCacheDirectory();
      await Hive.initFlutter(cacheDir.path);

      final box = await Hive.openBox<PageCacheEntry>(_boxName);
      _pinBox = await Hive.openBox<bool>(_pinBoxName);
      _pinnedBookIds
        ..clear()
        ..addAll(_pinBox!.keys.whereType<int>());
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
    var pinned = 0;
    for (final key in box.keys) {
      final entry = box.get(key);
      if (entry == null) continue;
      total += entry.sizeInBytes;
      if (_isPinnedKey(key as String)) pinned += entry.sizeInBytes;
      ordered.add((key, entry.timestamp));
    }
    ordered.sort((a, b) => a.$2.compareTo(b.$2));
    _sizeIndexBytes = total;
    _pinnedBytes = pinned;
    _lruKeys
      ..clear()
      ..addAll(ordered.map((e) => e.$1));
  }

  /// `page_cache_<bookId>_<pageNum>` 里的 bookId。
  int? _bookIdFromKey(String key) {
    if (!key.startsWith(_cachePrefix)) return null;
    final rest = key.substring(_cachePrefix.length);
    final split = rest.indexOf('_');
    if (split <= 0) return null;
    return int.tryParse(rest.substring(0, split));
  }

  bool _isPinnedKey(String key) {
    final bookId = _bookIdFromKey(key);
    return bookId != null && _pinnedBookIds.contains(bookId);
  }

  /// 这本书是否被显式下载过（页不过期、不参与淘汰）。
  bool isBookPinned(int bookId) => _pinnedBookIds.contains(bookId);

  /// Pin 整本书的页缓存。
  ///
  /// 必须在**写入之前**调用，下载过程中写进来的页才算 pin 的页；页缓存
  /// 本身不存 pin 标记，所以解除 pin 对已有页同样立即生效。
  Future<void> pinBook(int bookId) async {
    try {
      await _initialize();
      if (!_pinnedBookIds.add(bookId)) return;
      await _pinBox?.put(bookId, true);
      CacheLogger.log('pinned book $bookId');
    } catch (e) {
      CacheLogger.logError('pinBook', e);
    }
  }

  /// 解除 pin：已下载的页留在普通缓存里（14 天 TTL / LRU 重新生效）。
  Future<void> unpinBook(int bookId) async {
    try {
      await _initialize();
      if (!_pinnedBookIds.remove(bookId)) return;
      await _pinBox?.delete(bookId);
      // 这些页重新变成可淘汰的，容量账本要把它们算回去。
      final box = await Hive.openBox<PageCacheEntry>(_boxName);
      await _recountPinnedBytes(box);
      CacheLogger.log('unpinned book $bookId');
    } catch (e) {
      CacheLogger.logError('unpinBook', e);
    }
  }

  /// Pin 变更后重算 [_pinnedBytes]。pin/unpin 是低频操作（用户按按钮），
  /// 一次全表扫描可以接受；写入路径上仍然只靠增量。
  Future<void> _recountPinnedBytes(Box<PageCacheEntry> box) async {
    var pinned = 0;
    for (final key in box.keys) {
      if (!_isPinnedKey(key as String)) continue;
      pinned += box.get(key)?.sizeInBytes ?? 0;
    }
    _pinnedBytes = pinned;
    // 解除 pin 可能让缓存重新超限：顺手淘汰一次。
    await _enforceSizeLimit(box);
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
    if (_isPinnedKey(key)) _pinnedBytes -= sizeInBytes;
    if (_sizeIndexBytes < 0) _sizeIndexBytes = 0;
    if (_pinnedBytes < 0) _pinnedBytes = 0;
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

      if (age > _ttl.inMilliseconds && !_pinnedBookIds.contains(bookId)) {
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
      final pinned = _isPinnedKey(cacheKey);
      await box.put(cacheKey, entry);
      if (previous != null) {
        _sizeIndexBytes -= previous.sizeInBytes;
        if (pinned) _pinnedBytes -= previous.sizeInBytes;
      }
      _sizeIndexBytes += sizeInBytes;
      if (pinned) _pinnedBytes += sizeInBytes;
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
      // 页都删了，pin 也就没有意义：留着只会让这本书"看起来已离线"。
      await unpinBook(bookId);
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
      _pinnedBytes = 0;
      _lruKeys.clear();
      _pinnedBookIds.clear();
      await _pinBox?.clear();
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
        'pinnedSizeMB': _pinnedBytes / (1024 * 1024),
        'pinnedBooks': _pinnedBookIds.length,
        'maxSizeMB': _maxCacheSizeBytes / (1024 * 1024),
        'ttlDays': _ttl.inDays,
        'isOverSizeLimit': _sizeIndexBytes - _pinnedBytes > _maxCacheSizeBytes,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 某一本书在页缓存里的覆盖情况（离线状态聚合用）。
  ///
  /// 过期页不算（和读取路径一致），但 pin 的书不算过期 —— 否则离线行会
  /// 把刚下好的页当成"没下"。
  Future<BookPageCacheStats> getBookStats(int bookId) async {
    try {
      final box = await _getBox();
      final now = DateTime.now().millisecondsSinceEpoch;
      final pinned = _pinnedBookIds.contains(bookId);
      final prefix = '$_cachePrefix${bookId}_';
      var pages = 0;
      var bytes = 0;
      final pagesSet = <int>{};

      for (final key in box.keys) {
        final keyStr = key as String;
        if (!keyStr.startsWith(prefix)) continue;
        final entry = box.get(key);
        if (entry == null) continue;
        if (!pinned && now - entry.timestamp > _ttl.inMilliseconds) continue;
        final pageNum = int.tryParse(keyStr.substring(prefix.length));
        if (pageNum == null) continue;
        pagesSet.add(pageNum);
        pages++;
        bytes += entry.sizeInBytes;
      }

      return BookPageCacheStats(
        pages: pages,
        bytes: bytes,
        lastPage:
            pagesSet.isEmpty
                ? null
                : pagesSet.reduce((a, b) => a > b ? a : b),
        pinned: pinned,
      );
    } catch (e) {
      CacheLogger.logError('getBookStats', e);
      return const BookPageCacheStats(pages: 0, bytes: 0, pinned: false);
    }
  }

  /// 超阈值时按 LRU 批量淘汰，一直清到八成为止。
  ///
  /// 绝大多数写入在这里是 O(1)：可淘汰的部分没超就直接返回。清理一次清掉
  /// 两成余量，避免连续写入时每页都触发一轮删除。Pin 的页不参与淘汰 ——
  /// 它们正是用户显式下载的那部分。
  Future<void> _enforceSizeLimit(Box<PageCacheEntry> box) async {
    try {
      final evictable = _sizeIndexBytes - _pinnedBytes;
      if (evictable <= _maxCacheSizeBytes) return;

      final target = _maxCacheSizeBytes * 8 ~/ 10;
      var remaining = evictable;
      final victims = <String, int>{};
      for (final key in _lruKeys) {
        if (remaining <= target) break;
        if (_isPinnedKey(key)) continue;
        final entry = box.get(key);
        if (entry == null) continue;
        victims[key] = entry.sizeInBytes;
        remaining -= entry.sizeInBytes;
      }
      if (victims.isEmpty) return;

      await box.deleteAll(victims.keys);
      victims.forEach(_forget);
    } catch (e) {
      CacheLogger.logError('enforceSizeLimit', e);
    }
  }
}

/// 一本书在页缓存里的覆盖情况。
class BookPageCacheStats {
  const BookPageCacheStats({
    required this.pages,
    required this.bytes,
    required this.pinned,
    this.lastPage,
  });

  final int pages;
  final int bytes;
  final bool pinned;

  /// 缓存里编号最大的页（用来给下载挑一份可复用的 metadata）。
  final int? lastPage;
}
