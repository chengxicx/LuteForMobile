import 'book_progress_service.dart';
import 'books_cache_service.dart';
import 'audio_cache_service.dart';
import 'term_cache_service.dart';
import 'terms_list_cache_service.dart';
import 'tooltip_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/reader/services/page_cache_service.dart';
import '../../features/reader/services/sentence_cache_service.dart';
import '../../features/stats/repositories/stats_repository.dart';

/// 缓存的统一清理入口。
///
/// 缓存分成**性质完全不同的两类**，混在一个按钮里会出事（见设置页的
/// 「Storage」分区）：
///
/// - **页面/词条类**（[clearPageCaches]）：可再生，体积小，清掉只是下次打开
///   重新拉一次。登录/登出、用户想强制刷新页面内容时都走它。
/// - **音频**（[clearAudioCache]）：离线播放与影子跟读的根基，一本 6–64MB，
///   清掉就是重新走一遍流量。账号隔离场景（登录/登出/换服务器）必须清：
///   bookId 是各账号书架里的编号，留着会把 A 的音频放给 B。
class CacheManager {
  final BooksCacheService _booksCache;
  final TermCacheService _termCache;
  final TermsListCacheService _termsListCache;
  final TooltipCacheService _tooltipCache;
  final PageCacheService _pageCache;
  final SentenceCacheService _sentenceCache;
  final StatsRepository _statsRepository;
  final BookProgressService _bookProgress;
  final AudioCacheService _audioCache;

  CacheManager({
    required BooksCacheService booksCache,
    required TermCacheService termCache,
    required TermsListCacheService termsListCache,
    required TooltipCacheService tooltipCache,
    required PageCacheService pageCache,
    required SentenceCacheService sentenceCache,
    required StatsRepository statsRepository,
    required BookProgressService bookProgress,
    required AudioCacheService audioCache,
  }) : _booksCache = booksCache,
       _termCache = termCache,
       _termsListCache = termsListCache,
       _tooltipCache = tooltipCache,
       _pageCache = pageCache,
       _sentenceCache = sentenceCache,
       _statsRepository = statsRepository,
       _bookProgress = bookProgress,
       _audioCache = audioCache;

  /// 页面/词条类缓存：可再生，清掉只是下次打开重新拉一次。
  ///
  /// 也是登录/登出时的清理入口（换用户后别人的书、词条、统计都不该留着），
  /// 见 [clearServerDependentCaches]。
  Future<void> clearPageCaches() async {
    await Future.wait([
      _booksCache.clearAll(),
      _termCache.clearAll(),
      _termsListCache.clearAll(),
      _tooltipCache.clearAllCache(),
      _pageCache.clearAllCache(),
      _sentenceCache.clearAllCache(),
      _statsRepository.clearCache(),
      clearDictionaryPreferences(),
      // The remembered page per book lives in the same purgeable cache
      // dir as the page cache, so clearing one must clear the other --
      // otherwise we would keep a page pointer whose page is gone.
      _bookProgress.clearAll(),
    ]);
  }

  /// 音频缓存。**清之前先让播放器卸载音源**，否则它手里攥着一个已删除的
  /// `File`（见设置页 `StorageCacheSection`）。
  Future<void> clearAudioCache() async {
    await _audioCache.clearAll();
  }

  /// 登录/登出/换服务器用：页面缓存与音频缓存都清。
  ///
  /// 音频缓存以前刻意留着（按 bookId 存，重下几十 MB 代价高）。但 bookId 是
  /// **每个账号自己书架里的编号**：B 账号的 book 5 与 A 账号的 book 5 是两本
  /// 不同的书，留着就是让 B 播 A 的音频。账号隔离优先于流量，登录态变化时
  /// 一并清掉，下次播放重新下载。
  Future<void> clearServerDependentCaches() async {
    await Future.wait([clearPageCaches(), clearAudioCache()]);
  }

  /// 两类都清。用户显式要求「全清」时才用。
  Future<void> clearAllCaches() async {
    await Future.wait([clearPageCaches(), clearAudioCache()]);
  }

  /// 页面/词条类缓存的总字节数，供设置页显示。
  ///
  /// 只累加能报出体积的那几个（页面、句子、词条、词卡提示）；书架缓存与
  /// 词条列表缓存是纯文本元数据，几十 KB 量级，报出来对用户没有意义。
  Future<int> getPageCacheBytes() async {
    final stats = await Future.wait([
      _pageCache.getCacheStats(),
      _sentenceCache.getCacheStats(),
      _termCache.getCacheStats(),
      _tooltipCache.getCacheStats(),
    ]);
    var total = 0;
    for (final stat in stats) {
      final bytes = stat['totalSizeBytes'];
      if (bytes is int) total += bytes;
    }
    return total;
  }

  Future<void> clearDictionaryPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final dictionaryKeys = prefs
        .getKeys()
        .where(
          (key) =>
              key.startsWith('dictionaries_') ||
              key.startsWith('sentence_dictionaries_'),
        )
        .toList();

    await Future.wait(dictionaryKeys.map(prefs.remove));
  }
}
