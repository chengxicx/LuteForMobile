import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../cache/cache_logger.dart';

/// Durable home for the pending intents.
///
/// An interface rather than a bare Hive wrapper so the outbox service can be
/// unit-tested against [InMemoryOutboxStore] — no Hive, no disk, no
/// `path_provider` platform channel.
abstract class OutboxStore {
  /// Every stored intent, keyed by its coalesce key.
  Future<Map<String, String>> readAll();

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> clear();

  Future<void> close();
}

/// Hive-backed store, kept in the **application support** directory.
///
/// Not the cache directory: the whole point of the outbox is that the user's
/// edits survive, and the OS is free to purge the cache at any time.  A
/// pending edit that vanishes because the phone needed space is a silent data
/// loss the user cannot even detect.
///
/// The box is opened with an explicit `path:` on purpose.  `Hive.init` is
/// `homePath = path` with no guard — it silently overwrites the global — and
/// `PageCacheService` / `SentenceCacheService` / `CurrentBookCacheService`
/// each call `Hive.initFlutter(cacheDir.path)` from their own `_initialize()`.
/// Whoever runs last decides where every subsequently opened box lands, so
/// relying on the ambient home path here would put the outbox in the purgeable
/// cache dir on some launches and not others.  An explicit `path:` wins
/// (`_openBox` uses `path ?? homePath`).
class HiveOutboxStore implements OutboxStore {
  static const String _boxName = 'outbox';

  Box<String>? _box;
  bool _isInitialized = false;

  Future<Box<String>?> _getBox() async {
    if (!_isInitialized) {
      try {
        final dir = await getApplicationSupportDirectory();
        _box = await Hive.openBox<String>(_boxName, path: dir.path);
      } catch (e) {
        CacheLogger.logError('outbox open', e);
      }
      // Marked initialised either way: a broken store must degrade to "no
      // pending intents", not retry the open on every single call.
      _isInitialized = true;
    }
    return _box;
  }

  @override
  Future<Map<String, String>> readAll() async {
    try {
      final box = await _getBox();
      if (box == null) return {};
      return {
        for (final key in box.keys)
          if (box.get(key) != null) '$key': box.get(key)!,
      };
    } catch (e) {
      CacheLogger.logError('outbox readAll', e);
      return {};
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final box = await _getBox();
      await box?.put(key, value);
    } catch (e) {
      CacheLogger.logError('outbox write', e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final box = await _getBox();
      await box?.delete(key);
    } catch (e) {
      CacheLogger.logError('outbox delete', e);
    }
  }

  @override
  Future<void> clear() async {
    try {
      final box = await _getBox();
      await box?.clear();
      CacheLogger.logClear(_boxName);
    } catch (e) {
      CacheLogger.logError('outbox clear', e);
    }
  }

  @override
  Future<void> close() async {
    try {
      if (_box != null && _box!.isOpen) await _box!.close();
    } catch (e) {
      CacheLogger.logError('outbox close', e);
    }
    _box = null;
    _isInitialized = false;
  }
}

/// Test double.  Also the fallback shape if a platform has no Hive at all.
class InMemoryOutboxStore implements OutboxStore {
  final Map<String, String> _entries = {};

  @override
  Future<Map<String, String>> readAll() async => Map.of(_entries);

  @override
  Future<void> write(String key, String value) async => _entries[key] = value;

  @override
  Future<void> delete(String key) async => _entries.remove(key);

  @override
  Future<void> clear() async => _entries.clear();

  @override
  Future<void> close() async {}
}
