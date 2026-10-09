// 音频缓存的命名与孤儿回收 —— 直接决定"用户的离线音频会不会被误删"。
//
// 起因（2026-10-10 的 plan-2026-10-10-audio-duplicate-and-cache-ui.md）：
//   服务端给音源 URL 挂了 `?v=<音频文件 mtime>`（lute/book/service.py 的
//   media_audio_url），换了音频就换 URL；而旧的缓存文件名是
//   `audiobook_<bookId>_<audioUrl.hashCode.abs()>.audio` —— 版本只藏在 hash
//   里，事后反推不出来，于是旧版本文件永远没人回收，一份 6–64MB。
//
// 这里锁三件事：
//   1. 文件名里的版本是显式的、可解析的（新旧命名能区分开）；
//   2. 回收判定只删该删的 —— 尤其是 `knownBookIds` 为 null 时**不能**按
//      "书不在书架"删，冷启动拿不到书架会把用户的离线音频清空；
//   3. 同一本书留最新那份（`?v=` 变了留下的历史版本正是要堵的泄漏）。
//
// 运行：flutter test test/audio_cache_layout_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/cache/audio_cache_layout.dart';
import 'package:song_mobile/core/cache/audio_cache_service.dart';
import 'package:song_mobile/features/settings/widgets/storage_cache_section.dart';

/// 造一个已解析的缓存文件条目。
AudioCacheFile file(
  String name, {
  required int bookId,
  String? version,
  bool isPartial = false,
  int ageDays = 0,
  DateTime? now,
}) {
  final base = now ?? DateTime(2026, 10, 10, 12);
  return AudioCacheFile(
    fileName: name,
    bookId: bookId,
    version: version,
    isPartial: isPartial,
    modifiedAt: base.subtract(Duration(days: ageDays)),
  );
}

void main() {
  final now = DateTime(2026, 10, 10, 12);

  group('版本与命名', () {
    test('版本优先取 URL 上的 ?v=（服务端写的音频文件 mtime）', () {
      expect(
        audioCacheVersion(
          'https://s.example.com/useraudio/stream/297?v=1759900000',
        ),
        '1759900000',
      );
    });

    test('没有 ?v= 的远端音源退回 URL 哈希（只求不同 URL 不互相覆盖）', () {
      final version = audioCacheVersion('https://cdn.example.com/a.mp3');
      expect(version, startsWith('h'));
      expect(int.tryParse(version.substring(1)), isNotNull);
    });

    test('文件名把版本显式写进去', () {
      expect(
        audioCacheFileName(
          bookId: 297,
          audioUrl: 'https://s.example.com/useraudio/stream/297?v=1759900000',
        ),
        'audiobook_297_v1759900000.audio',
      );
    });
  });

  group('文件名解析', () {
    test('新命名：bookId + 版本', () {
      final parsed = parseAudioCacheFile(
        fileName: 'audiobook_297_v1759900000.audio',
        modifiedAt: now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.bookId, 297);
      expect(parsed.version, '1759900000');
      expect(parsed.isPartial, isFalse);
      expect(parsed.isLegacy, isFalse);
    });

    test('半截文件（.part）也认得出来', () {
      final parsed = parseAudioCacheFile(
        fileName: 'audiobook_297_v1759900000.audio.part',
        modifiedAt: now,
      );
      expect(parsed!.isPartial, isTrue);
      expect(parsed.version, '1759900000');
    });

    test('旧命名（版本藏在 hash 里）标成 legacy', () {
      final parsed = parseAudioCacheFile(
        fileName: 'audiobook_297_1234567890.audio',
        modifiedAt: now,
      );
      expect(parsed!.isLegacy, isTrue);
      expect(parsed.version, isNull);
      expect(parsed.bookId, 297);
    });

    test('不认识的文件返回 null —— 不该去删一个看不懂的文件', () {
      for (final name in [
        'other_297_v1.audio',
        'audiobook_x_v1.audio',
        'audiobook_297_v1.mp3',
        'audiobook_297_.audio',
        'audiobook_.audio',
      ]) {
        expect(
          parseAudioCacheFile(fileName: name, modifiedAt: now),
          isNull,
          reason: '$name 不该被认成我们的缓存文件',
        );
      }
    });
  });

  group('孤儿判定', () {
    test('旧命名一律回收（一次性迁移，之后按新命名重下）', () {
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_1_1234567890.audio', bookId: 1),
        file('audiobook_1_v1759900000.audio', bookId: 1, version: '1759900000'),
      ], now: now);

      expect(orphans, ['audiobook_1_1234567890.audio']);
    });

    test('书已不在书架 → 回收', () {
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_1_v1.audio', bookId: 1, version: '1'),
        file('audiobook_2_v1.audio', bookId: 2, version: '1'),
      ], now: now, knownBookIds: {1});

      expect(orphans, ['audiobook_2_v1.audio']);
    });

    test('书架未知（knownBookIds 为 null）时不按"书不在书架"删', () {
      // 冷启动拿不到书架，传空集合当"什么书都没有"会把用户的离线音频全删光。
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_1_v1.audio', bookId: 1, version: '1'),
        file('audiobook_2_v1.audio', bookId: 2, version: '1'),
      ], now: now);

      expect(orphans, isEmpty);
    });

    test('同一本书只留最新那份，历史版本回收', () {
      final orphans = selectOrphanAudioCacheFiles([
        file(
          'audiobook_297_v1759900000.audio',
          bookId: 297,
          version: '1759900000',
          ageDays: 5,
        ),
        file(
          'audiobook_297_v1759999999.audio',
          bookId: 297,
          version: '1759999999',
        ),
        file(
          'audiobook_297_v1759800000.audio',
          bookId: 297,
          version: '1759800000',
          ageDays: 9,
        ),
      ], now: now);

      expect(orphans, [
        'audiobook_297_v1759800000.audio',
        'audiobook_297_v1759900000.audio',
      ]);
    });

    test('mtime 打平时按版本号定胜负（目录列举顺序不保证稳定）', () {
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_297_v100.audio', bookId: 297, version: '100'),
        file('audiobook_297_v200.audio', bookId: 297, version: '200'),
      ], now: now);

      expect(orphans, ['audiobook_297_v100.audio']);
    });

    test('过期的 .part 回收，新鲜的留着续传', () {
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_1_v1.audio', bookId: 1, version: '1'),
        file(
          'audiobook_1_v2.audio.part',
          bookId: 1,
          version: '2',
          isPartial: true,
          ageDays: 10,
        ),
        file(
          'audiobook_1_v3.audio.part',
          bookId: 1,
          version: '3',
          isPartial: true,
        ),
      ], now: now, partialMaxAge: const Duration(days: 3));

      expect(orphans, ['audiobook_1_v2.audio.part']);
    });

    test('正在用的文件（keepFileNames）不回收', () {
      // 这份旧命名的文件本来会被回收，但它正是当前那条下载/播放手里的文件
      // —— 删了就会把还在写的 `.part` 的最终目标一起删掉。
      final orphans = selectOrphanAudioCacheFiles([
        file('audiobook_1_1234567890.audio', bookId: 1),
        file('audiobook_1_v2.audio', bookId: 1, version: '2'),
      ], now: now, keepFileNames: {'audiobook_1_1234567890.audio'});

      expect(orphans, isEmpty);
    });

    test('没东西可删时返回空', () {
      expect(
        selectOrphanAudioCacheFiles(const [], now: now),
        isEmpty,
      );
    });
  });

  group('AudioCacheService', () {
    late Directory base;

    setUp(() {
      base = Directory.systemTemp.createTempSync('lute_audio_cache');
    });

    tearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });

    Future<File> put(
      String name, {
      int bytes = 10,
      DateTime? modified,
    }) async {
      final dir = Directory('${base.path}/$kAudioCacheDirName');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(List<int>.filled(bytes, 0));
      if (modified != null) await file.setLastModified(modified);
      return file;
    }

    AudioCacheService service() =>
        AudioCacheService(cacheDirectory: () async => base);

    test('统计：体积 / 完整文件数 / 本数 / 半截数', () async {
      await put('audiobook_1_v1.audio', bytes: 100);
      await put('audiobook_2_v1.audio', bytes: 200);
      await put('audiobook_1_v1.audio.part', bytes: 50);

      final stats = await service().getStats();
      expect(stats.bytes, 350);
      expect(stats.fileCount, 2);
      expect(stats.bookCount, 2);
      expect(stats.partialCount, 1);
      expect(stats.isEmpty, isFalse);
    });

    test('目录还不存在时统计为空，而不是抛', () async {
      final stats = await service().getStats();
      expect(stats.isEmpty, isTrue);
      expect(stats.bytes, 0);
    });

    test('clearAll 连 .part 一起清掉', () async {
      await put('audiobook_1_v1.audio');
      await put('audiobook_2_v1.audio');
      await put('audiobook_1_v1.audio.part');

      expect(await service().clearAll(), 3);
      expect((await service().getStats()).isEmpty, isTrue);
    });

    test('clearForBook 只删这本书', () async {
      await put('audiobook_1_v1.audio');
      await put('audiobook_2_v1.audio');
      await put('audiobook_1_v2.audio.part');

      expect(await service().clearForBook(1), 2);
      final stats = await service().getStats();
      expect(stats.fileCount, 1);
      expect(stats.bookCount, 1);
    });

    test('collectOrphans 删掉旧命名与历史版本，留下最新那份', () async {
      final clock = DateTime.now();
      final old = await put(
        'audiobook_1_1234567890.audio',
        modified: clock.subtract(const Duration(days: 3)),
      );
      final stale = await put(
        'audiobook_1_v1759900000.audio',
        modified: clock.subtract(const Duration(days: 2)),
      );
      final fresh = await put(
        'audiobook_1_v1759999999.audio',
        modified: clock.subtract(const Duration(days: 1)),
      );

      expect(await service().collectOrphans(), 2);
      expect(await old.exists(), isFalse);
      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
    });

    test('collectOrphans 带书架时清掉已下架的书', () async {
      final gone = await put('audiobook_9_v1.audio');
      final kept = await put('audiobook_1_v1.audio');

      expect(await service().collectOrphans(knownBookIds: {1}), 1);
      expect(await gone.exists(), isFalse);
      expect(await kept.exists(), isTrue);
    });

    test('collectOrphans 在书架未知时一个都不删', () async {
      final a = await put('audiobook_1_v1.audio');
      final b = await put('audiobook_2_v1.audio');

      expect(await service().collectOrphans(), 0);
      expect(await a.exists(), isTrue);
      expect(await b.exists(), isTrue);
    });
  });

  group('formatCacheBytes', () {
    test('按量级挑单位，小体积不写成 0.0 MB', () {
      expect(formatCacheBytes(0), '0 B');
      expect(formatCacheBytes(512), '512 B');
      expect(formatCacheBytes(2048), '2 KB');
      expect(formatCacheBytes(6 * 1024 * 1024), '6.0 MB');
      expect(formatCacheBytes(64 * 1024 * 1024), '64 MB');
      expect(formatCacheBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });
  });
}
