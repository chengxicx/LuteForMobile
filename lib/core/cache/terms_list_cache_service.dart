import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../features/terms/models/term.dart';
import 'cache_logger.dart';

/// 词条屏（Terms screen）分页列表的离线快照。
///
/// 按「过滤条件组合」存一整份列表，而不是像 [TermCacheService] 那样按
/// termId 存单条 —— 词条屏的请求带 langId / search / status 过滤和分页，
/// 离线时要能原样恢复用户停住的那一屏。用 `Box<String>` 存 JSON 快照，
/// 不需要动 Hive adapter（同 books_series_cache 的做法）。
class TermsListCacheService {
  static const String _boxName = 'terms_list_cache';

  /// 词条列表变化频繁（每次阅读都在改状态），缓存只用于断网兜底，
  /// 一天就够：太久远的快照会把已删除/已改状态的词展示成现状。
  static const Duration _ttl = Duration(days: 1);

  Box<String>? _box;
  bool _isInitialized = false;

  TermsListCacheService();

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      _box = await Hive.openBox<String>(_boxName);
      _isInitialized = true;
      CacheLogger.log('initialized');
    } catch (e) {
      CacheLogger.logError('initialize', e);
      rethrow;
    }
  }

  /// 缓存键：过滤条件组合。search 文本直接进键（Hive key 是字符串），
  /// statuses 排序后拼接，保证同一组过滤永远映射到同一个键。
  String cacheKey({
    required int? langId,
    required String search,
    required Set<String> statuses,
  }) {
    final sortedStatuses = statuses.toList()..sort();
    return '${langId ?? 'all'}|${search.trim().toLowerCase()}|${sortedStatuses.join(',')}';
  }

  /// 该过滤组合下的离线快照，过期或损坏时返回 null（这一层只是兜底，
  /// 坏了不能让词条屏变错误态）。
  Future<List<Term>?> getTerms({
    required int? langId,
    required String search,
    required Set<String> statuses,
  }) async {
    try {
      if (!_isInitialized) await initialize();
      final box = _box;
      if (box == null) return null;

      final key = cacheKey(
        langId: langId,
        search: search,
        statuses: statuses,
      );
      final raw = box.get(key);
      if (raw == null) {
        CacheLogger.logMiss(_boxName, key.hashCode);
        return null;
      }

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = (decoded['t'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - savedAt >
          _ttl.inMilliseconds) {
        await box.delete(key);
        CacheLogger.logMiss(_boxName, key.hashCode);
        return null;
      }

      CacheLogger.logHit(_boxName, key.hashCode);
      return (decoded['l'] as List<dynamic>)
          .map((e) => Term.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      CacheLogger.logError('getTerms', e);
      return null;
    }
  }

  /// [terms] 用 [Term.toJson] 序列化；只缓存「服务端字段风格」的数据，
  /// 调用方传 state.terms 原样即可。
  Future<void> saveTerms(
    List<Term> terms, {
    required int? langId,
    required String search,
    required Set<String> statuses,
  }) async {
    try {
      if (!_isInitialized) await initialize();
      final box = _box;
      if (box == null) return;

      final key = cacheKey(
        langId: langId,
        search: search,
        statuses: statuses,
      );
      await box.put(
        key,
        jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'l': terms.map((e) => e.toJson()).toList(),
        }),
      );
      CacheLogger.log('saved ${terms.length} terms for "$key"');
    } catch (e) {
      CacheLogger.logError('saveTerms', e);
    }
  }

  /// 换服务器时整体作废：词条没有服务器标识，混着两个服务器的快照
  /// 会把 A 服务器的词展示成 B 服务器的现状。
  Future<void> clearAll() async {
    try {
      if (!_isInitialized) await initialize();
      await _box?.clear();
      CacheLogger.logClear(_boxName);
    } catch (e) {
      CacheLogger.logError('clearAll', e);
    }
  }

  Future<void> close() async {
    try {
      if (_box != null && _box!.isOpen) {
        await _box!.close();
      }
      _box = null;
      _isInitialized = false;
    } catch (e) {
      CacheLogger.logError('close', e);
    }
  }
}
