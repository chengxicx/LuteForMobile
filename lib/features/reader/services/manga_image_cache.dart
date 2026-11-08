import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/cache/providers/page_cache_provider.dart';
import '../../../core/logger/api_logger.dart';
import '../../../core/network/api_service.dart';
import '../../../shared/providers/network_providers.dart';

/// Per-book stats of the manga image cache.
class MangaImageStats {
  const MangaImageStats({required this.files, required this.bytes});

  final int files;
  final int bytes;
}

/// 漫画页图的自管磁盘缓存。
///
/// 原来图片走 [DefaultCacheManager]：全局约 200 个对象、30 天，一本漫画几十页
/// 就能把别的书挤出去，而且用户显式下载的书没有任何保护。这里按
/// `manga_images/<bookId>/<md5(imagePath)>.img` 落盘，配额分两层：
///
///  * 每本书 [maxBookBytes]：任何书（包括已下载的）都不会无限增长；
///  * 全局 [maxUnpinnedBytes]：只约束**没有显式下载**的书，按文件 mtime
///    做 LRU 淘汰。被 pin 的书不参与全局淘汰，这和页缓存的 pin 语义一致。
///
/// 文件按图片在服务器上的 path 做 key（不含 serverUrl），换服务器不串图。
class MangaImageCache {
  MangaImageCache({
    required ApiService api,
    required bool Function(int bookId) isPinned,
  }) : _api = api,
       _isPinned = isPinned;

  static const int maxBookBytes = 200 * 1024 * 1024;
  static const int maxUnpinnedBytes = 400 * 1024 * 1024;

  final ApiService _api;
  final bool Function(int bookId) _isPinned;

  final Map<String, Future<File?>> _inFlight = <String, Future<File?>>{};
  final Map<int, int> _bookBytes = <int, int>{};
  int _knownTotal = 0;
  bool _indexed = false;

  Future<Directory> _rootDir() async {
    final cacheDir = await getApplicationCacheDirectory();
    return Directory('${cacheDir.path}/manga_images');
  }

  Future<Directory> _bookDir(int bookId) async {
    final root = await _rootDir();
    return Directory('${root.path}/$bookId');
  }

  Future<File> _fileFor(int bookId, String imagePath) async {
    final dir = await _bookDir(bookId);
    final name = md5.convert(utf8.encode(imagePath)).toString();
    return File('${dir.path}/$name.img');
  }

  /// 已缓存的文件，命中时刷新 mtime（LRU 的"最近使用"）。
  Future<File?> existing(int bookId, String imagePath) async {
    if (imagePath.isEmpty) return null;
    try {
      final file = await _fileFor(bookId, imagePath);
      if (!await file.exists()) return null;
      await _touch(file);
      return file;
    } catch (e) {
      ApiLogger.logError('mangaImageExisting', e, details: imagePath);
      return null;
    }
  }

  /// 返回本地文件；没有就下载一份。失败返回 null（让调用方回退到网络）。
  ///
  /// 同一张图的并发请求共享同一个 future：页面在等图时，预取器再要
  /// 同一张图不会再发一次请求。
  Future<File?> ensure(int bookId, String imagePath) {
    if (imagePath.isEmpty) return Future<File?>.value(null);
    final key = '$bookId|$imagePath';
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _downloadIfMissing(bookId, imagePath, key);
    _inFlight[key] = future;
    return future;
  }

  Future<File?> _downloadIfMissing(
    int bookId,
    String imagePath,
    String key,
  ) async {
    try {
      final existingFile = await existing(bookId, imagePath);
      if (existingFile != null) return existingFile;

      final response = await _api.downloadAsset(imagePath);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;

      final file = await _fileFor(bookId, imagePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);

      await _ensureIndex();
      _bookBytes[bookId] = (_bookBytes[bookId] ?? 0) + bytes.length;
      _knownTotal += bytes.length;

      await _enforceBookQuota(bookId);
      await _enforceGlobalQuota();
      ApiLogger.logCache('mangaImageCache', details: 'stored $imagePath');
      return await file.exists() ? file : null;
    } catch (e) {
      ApiLogger.logError('mangaImageCache', e, details: imagePath);
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<MangaImageStats> statsForBook(int bookId) async {
    try {
      final dir = await _bookDir(bookId);
      if (!await dir.exists()) {
        return const MangaImageStats(files: 0, bytes: 0);
      }
      var files = 0;
      var bytes = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        files++;
        bytes += await entity.length();
      }
      return MangaImageStats(files: files, bytes: bytes);
    } catch (e) {
      ApiLogger.logError('mangaImageStats', e, details: 'bookId=$bookId');
      return const MangaImageStats(files: 0, bytes: 0);
    }
  }

  Future<void> deleteForBook(int bookId) async {
    try {
      final dir = await _bookDir(bookId);
      if (await dir.exists()) await dir.delete(recursive: true);
      await _ensureIndex();
      final removed = _bookBytes.remove(bookId) ?? 0;
      _knownTotal -= removed;
      if (_knownTotal < 0) _knownTotal = 0;
      ApiLogger.logCache('mangaImageCache', details: 'deleted book $bookId');
    } catch (e) {
      ApiLogger.logError('mangaImageDelete', e, details: 'bookId=$bookId');
    }
  }

  Future<void> clearAll() async {
    try {
      final root = await _rootDir();
      if (await root.exists()) await root.delete(recursive: true);
      _bookBytes.clear();
      _knownTotal = 0;
      _indexed = true;
    } catch (e) {
      ApiLogger.logError('mangaImageClearAll', e);
    }
  }

  /// 总量/单本账本只扫一次，之后随写入删除增量维护。
  Future<void> _ensureIndex() async {
    if (_indexed) return;
    _bookBytes.clear();
    _knownTotal = 0;
    final root = await _rootDir();
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final bookId = int.tryParse(entity.path.split(Platform.pathSeparator).last);
        if (bookId == null) continue;
        var bytes = 0;
        await for (final file in entity.list(followLinks: false)) {
          if (file is File) bytes += await file.length();
        }
        _bookBytes[bookId] = bytes;
        _knownTotal += bytes;
      }
    }
    _indexed = true;
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // mtime 只是 LRU 的提示，改不了不影响读取。
    }
  }

  Future<List<File>> _filesNewestLast(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    final stamps = <File, DateTime>{};
    for (final file in files) {
      try {
        stamps[file] = await file.lastModified();
      } catch (_) {
        stamps[file] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    files.sort((a, b) => stamps[a]!.compareTo(stamps[b]!));
    return files;
  }

  /// 单本配额：超过后按最久未用顺序删到八成。即使是用户显式下载的书
  /// 也受这个上限约束 —— 配额就是"这本书最多占多少"的承诺。
  Future<void> _enforceBookQuota(int bookId) async {
    final size = _bookBytes[bookId] ?? 0;
    if (size <= maxBookBytes) return;

    final target = maxBookBytes * 8 ~/ 10;
    var remaining = size;
    final dir = await _bookDir(bookId);
    if (!await dir.exists()) return;

    for (final file in await _filesNewestLast(dir)) {
      if (remaining <= target) break;
      final length = await file.length();
      try {
        await file.delete();
        remaining -= length;
        _knownTotal -= length;
        _bookBytes[bookId] = (_bookBytes[bookId] ?? 0) - length;
      } catch (_) {}
    }
  }

  /// 全局配额只约束未 pin 的书：用户按过 Download 的书不能被别的书挤掉。
  Future<void> _enforceGlobalQuota() async {
    var pinnedBytes = 0;
    _bookBytes.forEach((bookId, bytes) {
      if (_isPinned(bookId)) pinnedBytes += bytes;
    });
    final evictable = _knownTotal - pinnedBytes;
    if (evictable <= maxUnpinnedBytes) return;

    final target = maxUnpinnedBytes * 8 ~/ 10;
    var remaining = evictable;
    final root = await _rootDir();
    if (!await root.exists()) return;

    final candidates = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final bookId = int.tryParse(entity.path.split(Platform.pathSeparator).last);
      if (bookId == null || _isPinned(bookId)) continue;
      candidates.addAll(await _filesNewestLast(entity));
    }
    for (final file in candidates) {
      if (remaining <= target) break;
      final length = await file.length();
      final bookId = int.tryParse(
        file.parent.path.split(Platform.pathSeparator).last,
      );
      try {
        await file.delete();
        remaining -= length;
        _knownTotal -= length;
        if (bookId != null) {
          _bookBytes[bookId] = (_bookBytes[bookId] ?? 0) - length;
        }
      } catch (_) {}
    }
  }
}

final mangaImageCacheProvider = Provider<MangaImageCache>((ref) {
  return MangaImageCache(
    api: ref.watch(apiServiceProvider),
    isPinned: (bookId) => ref.read(pageCacheServiceProvider).isBookPinned(bookId),
  );
});
