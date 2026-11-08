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

  const AiAnalysisCacheEntry({
    required this.timestamp,
    required this.sizeInBytes,
    this.result,
    this.fallbackText,
    this.provider,
    this.model,
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
      );
    } catch (_) {
      return null;
    }
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
class AiAnalysisCacheService {
  final String _boxName;
  final Duration _ttl;
  final int _maxEntries;
  final int _maxCacheSizeBytes;

  Box<String>? _box;
  bool _isInitialized = false;

  /// [ttl], [maxEntries] and [maxCacheSizeBytes] exist so tests can shrink
  /// them; production uses the 14-day / 2000-entry / 20MB defaults, in line
  /// with the other caches.
  AiAnalysisCacheService({
    required String boxName,
    Duration? ttl,
    int? maxEntries,
    int? maxCacheSizeBytes,
  }) : _boxName = boxName,
       _ttl = ttl ?? const Duration(days: 14),
       _maxEntries = maxEntries ?? 2000,
       _maxCacheSizeBytes = maxCacheSizeBytes ?? 20 * 1024 * 1024;

  /// The Hive box backing this cache; tests use it to plant raw entries.
  String get boxName => _boxName;

  /// Cache key for an analysis request.  Results depend only on the sentence
  /// text and language, so the hash of both is the identity across sessions
  /// and books.
  static String cacheKey(int langId, String sentence) {
    return sha1.convert(utf8.encode('$langId|$sentence')).toString();
  }

  Future<void> initialize() async {
    try {
      if (!_isInitialized) {
        _box = await Hive.openBox<String>(_boxName);

        await _cleanupExpiredEntries();

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

      final age =
          DateTime.now().millisecondsSinceEpoch - entry.timestamp;
      if (age > _ttl.inMilliseconds) {
        await _box!.delete(key);
        CacheLogger.log('$_boxName MISS: key=$key (expired)');
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
  Future<bool> saveToCache({
    required String key,
    Map<String, dynamic>? result,
    String? fallbackText,
    String? provider,
    String? model,
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

      // `sizeInBytes` is itself part of the JSON, so encode once with a
      // placeholder to measure, then encode again with the real size (the
      // few-byte delta doesn't matter for stats).
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final measured = AiAnalysisCacheEntry(
        timestamp: timestamp,
        sizeInBytes: 0,
        result: result,
        fallbackText: fallbackText,
        provider: provider,
        model: model,
      );
      final size = utf8.encode(jsonEncode(measured.toJson())).length;
      final entry = AiAnalysisCacheEntry(
        timestamp: timestamp,
        sizeInBytes: size,
        result: result,
        fallbackText: fallbackText,
        provider: provider,
        model: model,
      );

      await _box!.put(key, jsonEncode(entry.toJson()));
      await _enforceSizeLimits();

      CacheLogger.log('$_boxName SAVE: key=$key');
      return true;
    } catch (e) {
      CacheLogger.logError('$_boxName.saveToCache', e);
      return false;
    }
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
      int validEntries = 0;
      int expiredEntries = 0;
      int totalEntries = _box!.length;

      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAge = _ttl.inMilliseconds;

      for (final key in _box!.keys) {
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry == null) continue;
        totalSize += entry.sizeInBytes;
        if (now - entry.timestamp > maxAge) {
          expiredEntries++;
        } else {
          validEntries++;
        }
      }

      return {
        'totalEntries': totalEntries,
        'validEntries': validEntries,
        'expiredEntries': expiredEntries,
        'totalSizeBytes': totalSize,
        'totalSizeMB': totalSize / (1024 * 1024),
        'maxSizeMB': _maxCacheSizeBytes / (1024 * 1024),
        'ttlHours': _ttl.inHours,
        'isOverSizeLimit': totalSize > _maxCacheSizeBytes,
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<void> _cleanupExpiredEntries() async {
    try {
      if (_box == null) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAge = _ttl.inMilliseconds;
      final expiredKeys = <String>[];

      for (final key in _box!.keys) {
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry == null || now - entry.timestamp > maxAge) {
          expiredKeys.add(key as String);
        }
      }

      if (expiredKeys.isNotEmpty) {
        await _box!.deleteAll(expiredKeys);
        CacheLogger.log('$_boxName cleaned up ${expiredKeys.length} expired entries');
      }
    } catch (e) {
      CacheLogger.logError('$_boxName.cleanupExpiredEntries', e);
    }
  }

  Future<void> _enforceSizeLimits() async {
    try {
      if (_box == null) return;

      await _cleanupExpiredEntries();

      int currentSize = 0;
      final entriesWithTimestamps = <String, int>{};

      for (final key in _box!.keys) {
        final entry = AiAnalysisCacheEntry.parse(_box!.get(key));
        if (entry == null) continue;
        currentSize += entry.sizeInBytes;
        entriesWithTimestamps[key as String] = entry.timestamp;
      }

      while (currentSize > _maxCacheSizeBytes ||
          entriesWithTimestamps.length > _maxEntries) {
        if (entriesWithTimestamps.isEmpty) break;
        final oldestKey = entriesWithTimestamps.keys.reduce(
          (a, b) =>
              entriesWithTimestamps[a]! < entriesWithTimestamps[b]! ? a : b,
        );

        final oldestEntry =
            AiAnalysisCacheEntry.parse(_box!.get(oldestKey));
        if (oldestEntry != null) {
          currentSize -= oldestEntry.sizeInBytes;
        }

        await _box!.delete(oldestKey);
        entriesWithTimestamps.remove(oldestKey);
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
