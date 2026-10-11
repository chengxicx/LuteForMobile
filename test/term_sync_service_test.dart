import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/cache/models/term_cache_entry.dart';
import 'package:song_mobile/core/cache/term_cache_service.dart';
import 'package:song_mobile/core/cache/term_sync_service.dart';

// 词库同步的纯逻辑回归：hash 没变就一个字节都不写、变了才全量落库、
// outbox 里还排着队的词以本地编辑为准不被覆盖。服务端 /term/sync 的
// 契约（map 键兼容 TermCacheEntry.fromServerJson、unchanged 短路）在
// 离线脚本里验过，这里锁的是消费侧。
void main() {
  late Directory tempDir;
  late TermCacheService cache;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_term_sync');
    Hive.init(tempDir.path);
    Hive.registerAdapter(TermCacheEntryAdapter());
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cache = TermCacheService();
    await cache.initialize();
    // 每个用例都从空库开始：box 名固定，不清的话上一个用例的词会漏进来。
    await Hive.box<TermCacheEntry>('term_cache').clear();
  });

  tearDownAll(() {
    Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> payload({
    String hash = 'h1',
    bool unchanged = false,
    List<Map<String, dynamic>>? terms,
  }) => {'hash': hash, if (unchanged) 'unchanged': true, 'terms': terms};

  Map<String, dynamic> serverTerm(int id, String text, {String? trans}) => {
    'WoID': id,
    'WoText': text,
    'WoTranslation': trans,
    'WoRomanization': null,
    'StID': 1,
    'LgID': 13,
    'ParentText': null,
  };

  test('首次同步：全量落库并记 hash', () async {
    final stored = <String>[];
    final service = TermSyncService(
      fetch: (_) async => payload(
        hash: 'h1',
        terms: [serverTerm(1, '箱', trans: '盒子'), serverTerm(2, '大きい')],
      ),
      apply: (entries) => cache.saveTerms(entries),
      storedHash: () async => stored.isEmpty ? null : stored.last,
      storeHash: (h) async => stored.add(h),
    );

    await service.syncIfChanged();

    expect(stored, ['h1']);
    expect((await cache.getTerm(1))?.translation, '盒子');
    expect(await cache.getTerm(2), isNotNull);
  });

  test('hash 没变：服务端回 unchanged，什么都不写', () async {
    SharedPreferences.setMockInitialValues({'term_sync_content_hash': 'h1'});
    var applied = 0;
    final service = TermSyncService(
      fetch: (_) async => payload(hash: 'h1', unchanged: true),
      apply: (entries) async {
        applied += entries.length;
        return true;
      },
      storedHash: () async => 'h1',
      storeHash: (_) async {},
    );

    await service.syncIfChanged();

    expect(applied, 0, reason: 'unchanged 短路，不该有写入');
  });

  test('outbox 里排着队的词跳过，hash 照记，下轮收敛', () async {
    final service = TermSyncService(
      fetch: (_) async => payload(
        hash: 'h2',
        terms: [serverTerm(1, '箱', trans: '盒子'), serverTerm(2, '大きい')],
      ),
      apply: (entries) => cache.saveTerms(entries),
      storedHash: () async => null,
      storeHash: (_) async {},
      pendingTermIds: () => {1}, // 箱 有还没冲刷的本地编辑
    );

    await service.syncIfChanged();

    expect(await cache.getTerm(1), isNull, reason: '本地编辑还没上服务器，别被快照盖回去');
    expect(await cache.getTerm(2), isNotNull);
  });

  test('请求失败：静默返回，不写 hash 不落库', () async {
    final stored = <String>[];
    var applied = 0;
    final service = TermSyncService(
      fetch: (_) async => null,
      apply: (entries) async {
        applied += entries.length;
        return true;
      },
      storedHash: () async => null,
      storeHash: (h) async => stored.add(h),
    );

    await service.syncIfChanged();

    expect(stored, isEmpty);
    expect(applied, 0);
  });
}
