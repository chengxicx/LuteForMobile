import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../outbox/providers/outbox_provider.dart';
import '../../shared/providers/network_providers.dart';
import 'cache_logger.dart';
import 'models/term_cache_entry.dart';
import 'providers/term_cache_provider.dart';

/// 词库同步：开阅读器时静默把服务器上的全部词条拉到本地 termCache。
///
/// 服务端 `GET /term/sync` 对全部词条算内容 hash：客户端带上上次同步的 hash，
/// 没变化时只回几十字节的 unchanged，变了才回全量 JSON（1.6 万词约 2MB）。
/// 本地存的是完整副本，所以：
///  - web 上补的翻译/注音，下次开书就回流到词卡（陈旧空缓存问题的根治）；
///  - 完全离线时，点任何学过的词都有完整兜底卡。
///
/// outbox 保护：还排在 outbox 里的词以本地编辑为准，这次跳过不覆盖
/// （outbox 冲刷后服务器内容变化，下一轮全量会再收敛）。hash 在跳过后
/// 照存——被丢弃的 intent 本来就等于服务器值，无陈旧可言。
class TermSyncService {
  TermSyncService({
    required Future<Map<String, dynamic>?> Function(String? storedHash) fetch,
    required Future<bool> Function(List<TermCacheEntry> entries) apply,
    required Future<String?> Function() storedHash,
    required Future<void> Function(String hash) storeHash,
    Set<int> Function() pendingTermIds = _noPending,
  }) : _fetch = fetch,
       _apply = apply,
       _storedHash = storedHash,
       _storeHash = storeHash,
       _pendingTermIds = pendingTermIds;

  final Future<Map<String, dynamic>?> Function(String? storedHash) _fetch;
  final Future<bool> Function(List<TermCacheEntry> entries) _apply;
  final Future<String?> Function() _storedHash;
  final Future<void> Function(String hash) _storeHash;
  final Set<int> Function() _pendingTermIds;

  static const String _hashKey = 'term_sync_content_hash';

  /// 同步永远静默：失败只是"这次没同步上"，绝不能打扰阅读。
  Future<void> syncIfChanged() async {
    try {
      final stored = await _storedHash();
      final data = await _fetch(stored);
      if (data == null) return;

      final serverHash = data['hash'] as String?;
      if (serverHash == null || serverHash.isEmpty) return;
      if (data['unchanged'] == true) return;

      final rawTerms = data['terms'];
      if (rawTerms is! List) return;

      final pending = _pendingTermIds();
      final entries = <TermCacheEntry>[];
      for (final item in rawTerms) {
        if (item is! Map<String, dynamic>) continue;
        final termId = item['WoID'];
        if (termId is! int) continue;
        if (pending.contains(termId)) continue;
        entries.add(TermCacheEntry.fromServerJson(item));
      }

      if (entries.isEmpty) {
        await _storeHash(serverHash);
        return;
      }

      final ok = await _apply(entries);
      if (!ok) return;
      await _storeHash(serverHash);
      CacheLogger.log('term sync applied (${entries.length} terms)');
    } catch (e) {
      CacheLogger.logError('termSync', e);
    }
  }

  static Set<int> _noPending() => const {};
}

final termSyncServiceProvider = Provider<TermSyncService>((ref) {
  return TermSyncService(
    fetch: (hash) => ref.read(apiServiceProvider).getTermSync(hash),
    apply: (entries) async {
      final cache = ref.read(termCacheServiceProvider);
      await cache.initialize();
      return cache.saveTerms(entries);
    },
    storedHash: () async =>
        (await SharedPreferences.getInstance()).getString(
          TermSyncService._hashKey,
        ),
    storeHash: (hash) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TermSyncService._hashKey, hash);
    },
    pendingTermIds: () =>
        ref.read(outboxProvider.notifier).pendingStatusByTermId.keys.toSet(),
  );
});
