import 'dart:async';
import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../features/books/models/book.dart';
import '../../features/books/models/book_cache_entry.dart';
import 'cache_logger.dart';

class BooksCacheService {
  static const String _boxName = 'books_cache';
  static const Duration _activeBooksTtl = Duration(days: 7);
  static const Duration _archivedBooksTtl = Duration(days: 14);

  /// 系列（Book Set）成员书单独放一个 box。
  ///
  /// [_box] 是 `Box<BookCacheEntry>`，塞不进别的类型；而给 `BookCacheEntry`
  /// 加字段要动 Hive adapter 和迁移。系列成员本质是「按 tag 分组的一串 Book」，
  /// 直接以 JSON 字符串存进一个 `Box<String>` 最省事，也不需要迁移。
  static const String _seriesBoxName = 'books_series_cache';

  /// 系列成员变化很慢，和书架同一档 TTL 足够。
  static const Duration _seriesTtl = Duration(days: 7);

  Box<BookCacheEntry>? _box;
  Box<String>? _seriesBox;
  bool _isInitialized = false;

  BooksCacheService();

  Future<void> initialize() async {
    try {
      if (!_isInitialized) {
        _box = await Hive.openBox<BookCacheEntry>(_boxName);
        _seriesBox = await Hive.openBox<String>(_seriesBoxName);

        await _cleanupExpiredEntries();

        _isInitialized = true;
        CacheLogger.log('initialized');
      }
    } catch (e) {
      CacheLogger.logError('initialize', e);
      rethrow;
    }
  }

  Future<List<Book>?> getActiveBooks() async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      if (_box == null) {
        CacheLogger.log('not initialized');
        return null;
      }

      final entry = _box!.get('books_data');
      if (entry == null) {
        CacheLogger.logMiss(_boxName, 'active_books'.hashCode);
        return null;
      }

      if (entry.isExpired(_activeBooksTtl)) {
        await _box!.delete('books_data');
        CacheLogger.logMiss(_boxName, 'active_books'.hashCode);
        return null;
      }

      CacheLogger.logHit(_boxName, 'active_books'.hashCode);
      return entry.activeBooks;
    } catch (e) {
      CacheLogger.logError('getActiveBooks', e);
      return null;
    }
  }

  Future<List<Book>?> getArchivedBooks() async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      if (_box == null) {
        CacheLogger.log('not initialized');
        return null;
      }

      final entry = _box!.get('books_data');
      if (entry == null) {
        CacheLogger.logMiss(_boxName, 'archived_books'.hashCode);
        return null;
      }

      if (entry.isExpired(_archivedBooksTtl)) {
        await _box!.delete('books_data');
        CacheLogger.logMiss(_boxName, 'archived_books'.hashCode);
        return null;
      }

      CacheLogger.logHit(_boxName, 'archived_books'.hashCode);
      return entry.archivedBooks;
    } catch (e) {
      CacheLogger.logError('getArchivedBooks', e);
      return null;
    }
  }

  Future<void> saveBooks({
    required List<Book> activeBooks,
    required List<Book> archivedBooks,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      if (_box == null) {
        CacheLogger.log('not initialized');
        return;
      }

      final entry = BookCacheEntry(
        activeBooks: activeBooks,
        archivedBooks: archivedBooks,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );

      await _box!.put('books_data', entry);
      CacheLogger.log(
        'saved ${activeBooks.length} active, ${archivedBooks.length} archived',
      );
    } catch (e) {
      CacheLogger.logError('saveBooks', e);
    }
  }

  /// 系列成员书的缓存键。tag 是任意文本，用前缀区分归档与否即可，
  /// Hive 的 key 本身就是字符串，不需要再做编码。
  String _seriesKey(String tag, bool archived) =>
      '${archived ? 'a' : 'n'}:$tag';

  /// 某个 Book Set 的成员书。
  ///
  /// 离线时书架上的聚合行仍然画得出来（它在书架缓存里），但点进去的成员
  /// 列表原先只能打网络，于是断网就永远停在 "Loading books..."。把成员列表
  /// 也缓存下来，聚合行才真正可点。
  Future<List<Book>?> getSeriesBooks(
    String tag, {
    bool archived = false,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      final box = _seriesBox;
      if (box == null) {
        CacheLogger.log('not initialized');
        return null;
      }

      final key = _seriesKey(tag, archived);
      final raw = box.get(key);
      if (raw == null) {
        CacheLogger.logMiss(_seriesBoxName, key.hashCode);
        return null;
      }

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = (decoded['t'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - savedAt >
          _seriesTtl.inMilliseconds) {
        await box.delete(key);
        CacheLogger.logMiss(_seriesBoxName, key.hashCode);
        return null;
      }

      CacheLogger.logHit(_seriesBoxName, key.hashCode);
      return (decoded['b'] as List<dynamic>)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 解不开就当作没缓存：这一层只是加速，坏了不能让页面变错误态。
      CacheLogger.logError('getSeriesBooks', e);
      return null;
    }
  }

  Future<void> saveSeriesBooks(
    String tag,
    List<Book> books, {
    bool archived = false,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      final box = _seriesBox;
      if (box == null) {
        CacheLogger.log('not initialized');
        return;
      }

      await box.put(
        _seriesKey(tag, archived),
        jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'b': books.map((e) => e.toJson()).toList(),
        }),
      );
      CacheLogger.log('saved ${books.length} series books for "$tag"');
    } catch (e) {
      CacheLogger.logError('saveSeriesBooks', e);
    }
  }

  Future<void> invalidateLanguage(String langName) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      if (_box == null) {
        CacheLogger.log('not initialized');
        return;
      }

      final entry = _box!.get('books_data');
      if (entry == null) {
        return;
      }

      final updatedActiveBooks = entry.activeBooks
          .where((book) => book.language != langName)
          .toList();

      final updatedArchivedBooks = entry.archivedBooks
          .where((book) => book.language != langName)
          .toList();

      if (updatedActiveBooks.length != entry.activeBooks.length ||
          updatedArchivedBooks.length != entry.archivedBooks.length) {
        final newEntry = BookCacheEntry(
          activeBooks: updatedActiveBooks,
          archivedBooks: updatedArchivedBooks,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        await _box!.put('books_data', newEntry);
        CacheLogger.log('invalidated language: $langName');
      }
    } catch (e) {
      CacheLogger.logError('invalidateLanguage', e);
    }
  }

  Future<void> clearAll() async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      if (_box == null) {
        CacheLogger.log('not initialized');
        return;
      }

      await _box!.clear();
      await _seriesBox?.clear();
      CacheLogger.logClear(_boxName);
    } catch (e) {
      CacheLogger.logError('clearAll', e);
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

      final entry = _box!.get('books_data');
      if (entry == null) {
        return {
          'hasEntry': false,
          'activeBooksCount': 0,
          'archivedBooksCount': 0,
        };
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final activeAge = now - entry.timestamp;
      final archivedAge = now - entry.timestamp;

      return {
        'hasEntry': true,
        'activeBooksCount': entry.activeBooks.length,
        'archivedBooksCount': entry.archivedBooks.length,
        'timestamp': entry.timestamp,
        'activeAgeMs': activeAge,
        'archivedAgeMs': archivedAge,
        'activeTtlDays': _activeBooksTtl.inDays,
        'archivedTtlDays': _archivedBooksTtl.inDays,
        'isActiveExpired': activeAge > _activeBooksTtl.inMilliseconds,
        'isArchivedExpired': archivedAge > _archivedBooksTtl.inMilliseconds,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<void> _cleanupExpiredEntries() async {
    try {
      if (_box == null) return;

      final entry = _box!.get('books_data');
      if (entry == null) return;

      final isActiveExpired = entry.isExpired(_activeBooksTtl);
      final isArchivedExpired = entry.isExpired(_archivedBooksTtl);

      if (isActiveExpired && isArchivedExpired) {
        await _box!.delete('books_data');
        CacheLogger.log('cleaned up expired entry');
      }
    } catch (e) {
      CacheLogger.logError('cleanupExpiredEntries', e);
    }
  }

  Future<void> close() async {
    try {
      if (_box != null && _box!.isOpen) {
        await _box!.close();
      }
      if (_seriesBox != null && _seriesBox!.isOpen) {
        await _seriesBox!.close();
      }
      _seriesBox = null;
      _isInitialized = false;
    } catch (e) {
      CacheLogger.logError('close', e);
    }
  }
}
