import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_cache_layout.dart';

/// 解析 app 缓存目录的方式。默认是 `path_provider`；测试注入临时目录，
/// 免得为了拿一个路径去起 platform channel。
typedef CacheDirectoryProvider = Future<Directory> Function();

/// 音频缓存的占用情况。
class AudioCacheStats {
  const AudioCacheStats({
    required this.bytes,
    required this.fileCount,
    required this.bookCount,
    required this.partialCount,
  });

  static const AudioCacheStats empty = AudioCacheStats(
    bytes: 0,
    fileCount: 0,
    bookCount: 0,
    partialCount: 0,
  );

  /// 目录里所有文件的字节数（含无法识别的文件与 `.part`）。
  final int bytes;

  /// 完整的缓存文件数。
  final int fileCount;

  /// 有完整缓存的有声书数量。
  final int bookCount;

  /// 半截文件数。
  final int partialCount;

  bool get isEmpty => fileCount == 0 && partialCount == 0;
}

/// 音频缓存（`<cacheDir>/audiobooks`）的管理入口。
///
/// 与页面/词条缓存分开，是因为两者性质完全不同：页面缓存可再生、体积小，
/// 清掉只是下次打开重新拉一次；音频缓存是**离线播放与影子跟读的根基**，
/// 一本 6–64MB，清掉就是重新走一遍流量。设置页因此给两个独立入口，而不是
/// 一个「一键全清」。
///
/// 文件命名与孤儿判定见 [audioCacheFileName] / [selectOrphanAudioCacheFiles]。
class AudioCacheService {
  AudioCacheService({CacheDirectoryProvider? cacheDirectory})
    : _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory;

  final CacheDirectoryProvider _cacheDirectory;

  Future<Directory> _directory({bool create = false}) async {
    final base = await _cacheDirectory();
    final dir = Directory('${base.path}/$kAudioCacheDirName');
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 当前占用。目录不存在（还没下过任何有声书）返回 [AudioCacheStats.empty]。
  Future<AudioCacheStats> getStats() async {
    try {
      final entries = await _listFiles();
      var bytes = 0;
      var fileCount = 0;
      var partialCount = 0;
      final books = <int>{};

      for (final entry in entries) {
        bytes += entry.size;
        final parsed = parseAudioCacheFile(
          fileName: entry.name,
          modifiedAt: entry.modifiedAt,
        );
        // 认不出来的文件也计入体积：卡片上的数字要能对上目录的真实占用，
        // 否则用户看到"清了 300MB，磁盘只少了 120MB"就再也不信这个数了。
        if (parsed == null) continue;
        if (parsed.isPartial) {
          partialCount++;
        } else {
          fileCount++;
          books.add(parsed.bookId);
        }
      }

      return AudioCacheStats(
        bytes: bytes,
        fileCount: fileCount,
        bookCount: books.length,
        partialCount: partialCount,
      );
    } catch (e) {
      debugPrint('AudioCache: 统计失败: $e');
      return AudioCacheStats.empty;
    }
  }

  /// 清空整个音频缓存（含 `.part`）。返回删掉的文件数。
  ///
  /// 调用方要先让播放器卸载音源（`audioPlayerProvider.notifier.reset()`），
  /// 否则播放器手里还攥着一个已经被删掉的 `File`。
  Future<int> clearAll() async {
    try {
      final dir = await _directory();
      if (!await dir.exists()) return 0;
      var removed = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          await entity.delete();
          removed++;
        } catch (e) {
          debugPrint('AudioCache: 删除失败 ${entity.path}: $e');
        }
      }
      debugPrint('AudioCache: 清空音频缓存，删除 $removed 个文件');
      return removed;
    } catch (e) {
      debugPrint('AudioCache: 清空失败: $e');
      return 0;
    }
  }

  /// 清掉某一本书的音频缓存。返回删掉的文件数。
  Future<int> clearForBook(int bookId) async {
    try {
      final dir = await _directory();
      if (!await dir.exists()) return 0;
      var removed = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final parsed = parseAudioCacheFile(
          fileName: _basename(entity.path),
          modifiedAt: DateTime.now(),
        );
        if (parsed?.bookId != bookId) continue;
        try {
          await entity.delete();
          removed++;
        } catch (e) {
          debugPrint('AudioCache: 删除失败 ${entity.path}: $e');
        }
      }
      debugPrint('AudioCache: 清掉 book $bookId 的音频缓存，删除 $removed 个文件');
      return removed;
    } catch (e) {
      debugPrint('AudioCache: 按书清理失败: $e');
      return 0;
    }
  }

  /// 回收孤儿文件（旧命名、书已下架、同书的旧版本、过期的 `.part`）。
  ///
  /// 判定规则见 [selectOrphanAudioCacheFiles]。[knownBookIds] 为 null 时
  /// 不做"书是否还在书架"的判定 —— 冷启动拿不到书架，用空集合会把用户的
  /// 离线音频全删了。
  Future<int> collectOrphans({
    Set<int>? knownBookIds,
    Set<String> keepFileNames = const {},
    Duration partialMaxAge = const Duration(days: 3),
  }) async {
    try {
      final dir = await _directory();
      if (!await dir.exists()) return 0;

      final entries = await _listFiles();
      final parsed = <AudioCacheFile>[];
      for (final entry in entries) {
        final file = parseAudioCacheFile(
          fileName: entry.name,
          modifiedAt: entry.modifiedAt,
        );
        if (file != null) parsed.add(file);
      }

      final orphans = selectOrphanAudioCacheFiles(
        parsed,
        now: DateTime.now(),
        knownBookIds: knownBookIds,
        keepFileNames: keepFileNames,
        partialMaxAge: partialMaxAge,
      );
      if (orphans.isEmpty) return 0;

      var removed = 0;
      for (final name in orphans) {
        try {
          await File('${dir.path}/$name').delete();
          removed++;
        } catch (e) {
          debugPrint('AudioCache: 回收失败 $name: $e');
        }
      }
      debugPrint('AudioCache: 回收孤儿文件 $removed 个');
      return removed;
    } catch (e) {
      debugPrint('AudioCache: 回收孤儿失败: $e');
      return 0;
    }
  }

  Future<List<_CacheFileEntry>> _listFiles() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];

    final entries = <_CacheFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        entries.add(
          _CacheFileEntry(
            name: _basename(entity.path),
            size: stat.size,
            modifiedAt: stat.modified,
          ),
        );
      } catch (e) {
        debugPrint('AudioCache: 读取 ${entity.path} 失败: $e');
      }
    }
    return entries;
  }

  /// 文件名。用 `uri.pathSegments` 而不是 `split(Platform.pathSeparator)`：
  /// 前者对两种分隔符都成立。
  String _basename(String path) => Uri.file(path).pathSegments.last;
}

class _CacheFileEntry {
  const _CacheFileEntry({
    required this.name,
    required this.size,
    required this.modifiedAt,
  });

  final String name;
  final int size;
  final DateTime modifiedAt;
}
