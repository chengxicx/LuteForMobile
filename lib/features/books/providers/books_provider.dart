import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import '../../../core/logger/api_logger.dart';
import '../models/book.dart';
import '../models/book_create.dart';
import '../repositories/books_repository.dart';
import '../../../shared/providers/network_providers.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/providers/app_startup_providers.dart';
import '../../../core/cache/providers/books_cache_provider.dart';

@immutable
class BooksState {
  final bool isLoading;
  final bool isRefreshing;
  final List<Book> activeBooks;
  final List<Book> archivedBooks;
  final bool showArchived;
  final String? errorMessage;
  final String searchQuery;
  final int? currentBookId;
  final bool hasMoreActive;
  final bool hasMoreArchived;

  /// 当前选中的 tag 过滤（对应 web 端的 `filtTag` 精确匹配）。
  final String? selectedTag;

  /// tag 过滤请求进行中。
  final bool tagFilterLoading;

  /// tag 过滤的服务端结果（扁平书单，聚合行已被服务端关闭）。
  /// selectedTag 为 null 时恒为 null。
  final List<Book>? tagFilteredBooks;

  /// copyWith 的「未传参」哨兵，让 String?/List? 字段能显式置 null。
  static const Object _unset = Object();

  const BooksState({
    this.isLoading = false,
    this.isRefreshing = false,
    this.activeBooks = const [],
    this.archivedBooks = const [],
    this.showArchived = false,
    this.errorMessage,
    this.searchQuery = '',
    this.currentBookId,
    this.hasMoreActive = true,
    this.hasMoreArchived = true,
    this.selectedTag,
    this.tagFilterLoading = false,
    this.tagFilteredBooks,
  });

  BooksState copyWith({
    bool? isLoading,
    bool? isRefreshing,
    List<Book>? activeBooks,
    List<Book>? archivedBooks,
    bool? showArchived,
    String? errorMessage,
    String? searchQuery,
    int? currentBookId,
    bool? hasMoreActive,
    bool? hasMoreArchived,
    Object? selectedTag = _unset,
    bool? tagFilterLoading,
    Object? tagFilteredBooks = _unset,
  }) {
    return BooksState(
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      activeBooks: activeBooks ?? this.activeBooks,
      archivedBooks: archivedBooks ?? this.archivedBooks,
      showArchived: showArchived ?? this.showArchived,
      errorMessage: errorMessage ?? this.errorMessage,
      searchQuery: searchQuery ?? this.searchQuery,
      currentBookId: currentBookId ?? this.currentBookId,
      hasMoreActive: hasMoreActive ?? this.hasMoreActive,
      hasMoreArchived: hasMoreArchived ?? this.hasMoreArchived,
      selectedTag: selectedTag == _unset
          ? this.selectedTag
          : selectedTag as String?,
      tagFilterLoading: tagFilterLoading ?? this.tagFilterLoading,
      tagFilteredBooks: tagFilteredBooks == _unset
          ? this.tagFilteredBooks
          : tagFilteredBooks as List<Book>?,
    );
  }
}

class BooksNotifier extends Notifier<BooksState> {
  late BooksRepository _repository;
  bool _isRefreshingBook = false;
  bool _refreshRequestedAfterNavigate = false;
  bool _isLoadingArchivedBooks = false;
  bool _isLoadingFromNetwork = false;
  bool _isLoadingBooks = false;
  bool _isBackgroundRefreshing = false;
  int? _lastBackgroundRefreshTime;
  String? _previousServerUrl;
  bool _isInitialized = false;
  bool _isResolvingActiveAudioMetadata = false;
  bool _isResolvingArchivedAudioMetadata = false;
  ProviderSubscription<bool>? _readerReadinessSubscription;

  /// tag 聚合行的统计补算状态。
  /// 聚合行背后被隐藏的成员书永远拿不到「按书统计刷新」的机会，
  /// 所以需要单独补算一次（见 _warmSeriesStatsIfNeeded）。
  bool _isWarmingSeriesStats = false;
  final Set<String> _seriesStatsWarmedSeries = <String>{};

  final int _pageSize = 10;
  int _activePage = 0;
  int _archivedPage = 0;
  bool _isLoadingMoreActive = false;
  bool _isLoadingMoreArchived = false;
  bool _pendingSearchReload = false;

  @override
  BooksState build() {
    _repository = ref.watch(booksRepositoryProvider);
    final settings = ref.watch(settingsProvider);

    // Reset loading flags on each build to prevent stuck states
    _isLoadingBooks = false;
    _isLoadingFromNetwork = false;
    _isBackgroundRefreshing = false;

    final serverUrl = settings.serverUrl;

    // Always initialize on first build of this notifier instance
    if (!_isInitialized) {
      _isInitialized = true;
      _previousServerUrl = serverUrl.isEmpty ? null : serverUrl;
      Future.microtask(() => _waitForReaderAndLoadBooks());
    } else {
      final (nextPrevious, serverChanged) = resolveServerUrlChange(
        _previousServerUrl,
        serverUrl,
      );
      _previousServerUrl = nextPrevious;
      if (serverChanged) {
        Future.microtask(() => _onServerChanged());
      }
    }

    return const BooksState();
  }

  /// 判断「设置里的 serverUrl 变化」该怎么处理。
  ///
  /// 返回 `(要记下的 previous 值, 是否算换了服务器)`。
  ///
  /// 设置是异步从 SharedPreferences 读出来的，本 provider 的首帧拿到的是
  /// `Settings.defaultSettings()` 里的**空 URL**。空串绝不能当成「上一次的
  /// 服务器」记下来：设置加载完成后的真实 URL 会被判成「换了服务器」，于是
  /// 每次启动都触发 [_onServerChanged]，把书目缓存清空 —— 表现是每次启动都
  /// 白跑一次全量网络同步，断网时书架直接空白（缓存刚被自己清掉）。
  /// 用 null 表示「还没拿到过真实 URL」，只有两个真实 URL 之间的切换才算换。
  @visibleForTesting
  static (String?, bool) resolveServerUrlChange(
    String? previous,
    String current,
  ) {
    // 设置还没读出来：这一帧没有可比较的信息。
    if (current.isEmpty) return (previous, false);
    // 第一次拿到真实 URL：只记录，不当成切换。
    if (previous == null || previous.isEmpty) return (current, false);
    // 真的换了服务器。
    if (previous != current) return (current, true);
    return (previous, false);
  }

  /// Waits for reader to signal ready, then loads books.
  /// Uses a 10-second fallback if reader never signals (e.g., user opens books screen directly).
  Future<void> _waitForReaderAndLoadBooks() async {
    // Check if reader is already ready
    if (ref.read(readerReadinessProvider)) {
      await _loadBooksAndSignalComplete();
      return;
    }

    // Set up a listener for reader readiness
    bool booksLoaded = false;
    _readerReadinessSubscription = ref.listen(readerReadinessProvider, (
      previous,
      next,
    ) {
      if (next == true && !booksLoaded) {
        booksLoaded = true;
        _readerReadinessSubscription?.close();
        _readerReadinessSubscription = null;
        _loadBooksAndSignalComplete();
      }
    });

    // Fallback: load books after 10 seconds if reader never signals ready
    Future.delayed(const Duration(seconds: 10), () {
      if (!booksLoaded) {
        booksLoaded = true;
        _readerReadinessSubscription?.close();
        _readerReadinessSubscription = null;
        _loadBooksAndSignalComplete();
      }
    });
  }

  /// Loads books and signals completion (even on error, since cache might have partial data).
  Future<void> _loadBooksAndSignalComplete() async {
    try {
      await loadBooks(forceRefresh: true);
    } finally {
      // Signal that books loading is complete, even if there was an error
      // (partial cache data may still be valuable)
      // Use microtask to avoid modifying provider during build
      Future.microtask(() {
        ref.read(booksLoadingCompleteProvider.notifier).markComplete();
      });
    }
  }

  Future<void> _onServerChanged() async {
    // Clear the cache when server changes to avoid mixing books from different servers
    await _repository.saveBooksToCache(activeBooks: [], archivedBooks: []);

    state = state.copyWith(
      activeBooks: const [],
      archivedBooks: const [],
      errorMessage: null,
    );
    _repository.resetLanguageMap();
    await loadBooks(forceRefresh: true);
  }

  Future<void> loadBooks({
    bool forceRefresh = false,
    bool skipExpiredBookRefresh = false,
  }) async {
    // Cancel any pending reader readiness listener to prevent duplicate loads
    _readerReadinessSubscription?.close();
    _readerReadinessSubscription = null;

    if (_isLoadingBooks) {
      return;
    }

    _isLoadingBooks = true;

    if (!_repository.contentService.isConfigured) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Server URL not configured. Please set it in settings.',
      );
      _isLoadingBooks = false;
      return;
    }

    if (forceRefresh) {
      _lastBackgroundRefreshTime = null;
    }

    // 已经有书目时不要翻 isLoading：书架标签每次点开都会走一次 loadBooks，
    // 翻成 true 就会先闪一屏 "Loading books..." 再跳回列表（下拉刷新同理，
    // 那种场景该由 RefreshIndicator 自己转）。真的没书可显示时才转圈。
    final hasBooksToShow =
        state.activeBooks.isNotEmpty || state.archivedBooks.isNotEmpty;
    state = state.copyWith(isLoading: !hasBooksToShow, errorMessage: null);

    try {
      final activeFromCache = await _repository.getActiveBooksFromCache();
      final archivedFromCache = await _repository.getArchivedBooksFromCache();

      final hasCachedBooks =
          activeFromCache != null && activeFromCache.isNotEmpty;
      ApiLogger.logCache(
        'loadBooks',
        details:
            'hasCachedBooks=$hasCachedBooks, count=${activeFromCache?.length ?? 0}',
      );

      if (hasCachedBooks) {
        state = state.copyWith(
          isLoading: false,
          activeBooks: activeFromCache,
          archivedBooks: archivedFromCache ?? state.archivedBooks,
        );
      } else {
        state = state.copyWith(isLoading: false);
      }
      await _loadBooksFromNetwork();
      // Only refresh expired books in background if not explicitly skipped.
      // Skip when followed by a full refresh (e.g., pull-to-refresh).
      if (!skipExpiredBookRefresh &&
          ref.read(settingsProvider).autoRefreshFullStats) {
        refreshExpiredBooks();
      }
    } catch (e) {
      state = state.copyWith(isLoading: false);
      ApiLogger.logError('loadBooksFromCache', e);
    } finally {
      _isLoadingBooks = false;
    }
  }

  /// 语言过滤只在显示层做（books_screen 按设置里的 languageFilter 过滤），
  /// state.activeBooks 恒存全量：
  /// 1) 切换语言过滤即时生效，不必等一次完整的网络同步；
  /// 2) 后台路径（音频解析、统计刷新）把 state 写回缓存时不会再把
  ///    过滤后的子集存进去污染缓存（实测会：过滤后重启前一直丢书）。

  void setCurrentBook(int? bookId) {
    if (bookId != null && bookId != state.currentBookId) {
      state = state.copyWith(currentBookId: bookId);
    }
  }

  Future<void> refreshExpiredBooks({bool forceRefreshAll = false}) async {
    if (_isBackgroundRefreshing) {
      return;
    }
    _isBackgroundRefreshing = true;

    final now = DateTime.now().millisecondsSinceEpoch;
    const globalCooldownMs = 120 * 1000;

    if (_lastBackgroundRefreshTime != null) {
      final timeSinceLastRefresh = now - _lastBackgroundRefreshTime!;
      if (timeSinceLastRefresh < globalCooldownMs) {
        _isBackgroundRefreshing = false;
        return;
      }
    }

    if (forceRefreshAll) {
      state = state.copyWith(isRefreshing: true, errorMessage: null);
    }

    try {
      final settings = ref.read(settingsProvider);
      final perBookCooldown = Duration(
        hours: settings.statsRefreshCooldownHours,
      );

      // tag 聚合行（Book.isSeries）没有自己的 BkID，不能参与「按书」的统计刷新：
      // 它的 lastStatsRefresh 恒为 null，会被无条件选中，然后对
      // /book/table_stats/0 发请求并失败，把整批刷新一起拖垮。
      final refreshable = state.activeBooks.where((book) => !book.isSeries);
      final booksToRefresh = forceRefreshAll
          ? refreshable.toList()
          : refreshable.where((book) {
              if (book.lastStatsRefresh == null) return true;
              final age = now - book.lastStatsRefresh!;
              return age > perBookCooldown.inMilliseconds;
            }).toList();

      ApiLogger.logCache(
        'refreshExpiredBooks',
        details:
            'forceRefreshAll=$forceRefreshAll, ${booksToRefresh.length} books out of ${state.activeBooks.length}',
      );

      if (booksToRefresh.isEmpty) {
        _lastBackgroundRefreshTime = now;
        if (forceRefreshAll) {
          state = state.copyWith(isRefreshing: false);
        }
        return;
      }

      try {
        await _repository.invalidateAllBookStatsCache(
          timeout: const Duration(seconds: 15),
        );

        await _repository.contentService.setUserSetting(
          'stats_calc_sample_size',
          settings.stats500SampleSize.toString(),
        );

        final updatedActiveBooks = List<Book>.from(state.activeBooks);

        const statsTimeout = Duration(seconds: 15);
        final futures = booksToRefresh
            .map(
              (book) => _refreshBookSimple(
                book.id,
                updatedBooksList: updatedActiveBooks,
                timeout: statsTimeout,
              ),
            )
            .toList();
        await Future.wait(futures);

        await _repository.saveBooksToCache(
          activeBooks: updatedActiveBooks,
          archivedBooks: state.archivedBooks,
        );

        state = state.copyWith(
          isRefreshing: false,
          activeBooks: updatedActiveBooks,
        );
      } catch (e) {
        if (forceRefreshAll) {
          state = state.copyWith(
            isRefreshing: false,
            errorMessage: e.toString(),
          );
        }
        rethrow;
      } finally {
        try {
          final settings = ref.read(settingsProvider);
          await _repository.contentService.setUserSetting(
            'stats_calc_sample_size',
            settings.statsCalcSampleSize.toString(),
          );
        } catch (e) {
          ApiLogger.logError('restoreSampleSize', e);
        }
      }

      _lastBackgroundRefreshTime = now;
    } finally {
      _isBackgroundRefreshing = false;
    }
  }

  Future<void> _refreshBookSimple(
    int bookId, {
    List<Book>? updatedBooksList,
    Duration? timeout,
  }) async {
    ApiLogger.logRequest('_refreshBookSimple', details: 'bookId=$bookId');

    final booksList = updatedBooksList ?? state.activeBooks;
    final existingBook = booksList.firstWhere(
      (book) => book.id == bookId,
      orElse: () =>
          throw Exception('Book with id $bookId not found in active books'),
    );
    final statsBook = await _repository.contentService.getBookStats(
      bookId,
      timeout: timeout,
    );
    ApiLogger.logRequest(
      '_refreshBookSimple',
      details: 'bookId=$bookId, distinctTerms=${statsBook.distinctTerms}',
    );
    final updatedBook = existingBook.copyWith(
      distinctTerms: statsBook.distinctTerms,
      unknownPct: statsBook.unknownPct,
      statusDistribution: statsBook.statusDistribution,
      lastStatsRefresh: DateTime.now().millisecondsSinceEpoch,
    );

    if (updatedBooksList != null) {
      final index = updatedBooksList.indexWhere((book) => book.id == bookId);
      if (index != -1) {
        updatedBooksList[index] = updatedBook;
      }
    }
  }

  Future<void> _refreshBookWith500SampleSize(
    int bookId, {
    List<Book>? updatedBooksList,
  }) async {
    if (_isRefreshingBook) {
      _refreshRequestedAfterNavigate = true;
      return;
    }

    _isRefreshingBook = true;
    _refreshRequestedAfterNavigate = false;

    final settings = ref.read(settingsProvider);

    try {
      await _repository.contentService.setUserSetting(
        'stats_calc_sample_size',
        settings.stats500SampleSize.toString(),
      );

      final booksList = updatedBooksList ?? state.activeBooks;
      final existingBook = booksList.firstWhere(
        (book) => book.id == bookId,
        orElse: () =>
            throw Exception('Book with id $bookId not found in active books'),
      );
      final statsBook = await _repository.contentService.getBookStats(
        bookId,
        timeout: const Duration(seconds: 15),
      );
      final updatedBook = existingBook.copyWith(
        distinctTerms: statsBook.distinctTerms,
        unknownPct: statsBook.unknownPct,
        statusDistribution: statsBook.statusDistribution,
        lastStatsRefresh: DateTime.now().millisecondsSinceEpoch,
      );

      // Update only the specific book in the provided list or in the state
      if (updatedBooksList != null) {
        final index = updatedBooksList.indexWhere((book) => book.id == bookId);
        if (index != -1) {
          updatedBooksList[index] = updatedBook;
        }
      } else {
        // Update the state normally (for non-batch updates)
        final updatedActiveBooks = state.activeBooks.map((book) {
          if (book.id == bookId) {
            return book.copyWith(
              title: updatedBook.title,
              language: updatedBook.language,
              langId: updatedBook.langId,
              totalPages: updatedBook.totalPages,
              currentPage: updatedBook.currentPage,
              percent: updatedBook.percent,
              wordCount: updatedBook.wordCount,
              distinctTerms: updatedBook.distinctTerms,
              unknownPct: updatedBook.unknownPct,
              statusDistribution: updatedBook.statusDistribution,
              tags: updatedBook.tags,
              lastRead: updatedBook.lastRead,
              isCompleted: updatedBook.isCompleted,
              lastStatsRefresh: updatedBook.lastStatsRefresh,
              audioFilename: updatedBook.audioFilename,
            );
          }
          return book;
        }).toList();

        state = state.copyWith(
          activeBooks: updatedActiveBooks,
          archivedBooks: state.archivedBooks,
        );

        // Save to cache asynchronously without waiting to avoid blocking the UI
        // This reduces the frequency of cache writes while still persisting the changes
        // Only do this when NOT in batch mode (batch mode handles its own save)
        if (updatedBooksList == null) {
          () async {
            try {
              await _repository.saveBooksToCache(
                activeBooks: updatedActiveBooks,
                archivedBooks: state.archivedBooks,
              );
            } catch (e) {
              ApiLogger.logError('saveBooksToCache', e);
            }
          }();
        }
      }
    } finally {
      _isRefreshingBook = false;
      try {
        final settings = ref.read(settingsProvider);
        await _repository.contentService.setUserSetting(
          'stats_calc_sample_size',
          settings.statsCalcSampleSize.toString(),
        );
      } catch (e) {
        ApiLogger.logError('restoreSampleSize', e);
      }
      if (_refreshRequestedAfterNavigate) {
        _refreshRequestedAfterNavigate = false;
        final currentBookId = state.currentBookId;
        if (currentBookId != null) {
          await _refreshBookWith500SampleSize(currentBookId);
        }
      }
    }
  }

  Future<void> _loadBooksFromNetwork() async {
    if (_isLoadingFromNetwork) return;
    _isLoadingFromNetwork = true;
    final requestQuery = state.searchQuery;

    try {
      final settings = ref.read(settingsProvider);
      await _repository.contentService.setUserSetting(
        'stats_calc_sample_size',
        settings.statsCalcSampleSize.toString(),
      );

      _activePage = 0;
      final List<Book> networkBooks;
      if (requestQuery.isEmpty) {
        // Full sync with the server: the server's active endpoint excludes
        // archived books, so replace the local list to drop any books that
        // were archived/frozen on the server but linger in the cache.
        networkBooks = await _repository.getAllActiveBooks();
        if (state.searchQuery != requestQuery) {
          _pendingSearchReload = true;
          return;
        }

        final finalActiveBooks = _mergeServerBooks(
          networkBooks,
          state.activeBooks,
        );

        await _repository.saveBooksToCache(
          activeBooks: finalActiveBooks,
          archivedBooks: state.archivedBooks,
        );

        state = state.copyWith(
          isLoading: false,
          activeBooks: finalActiveBooks,
          archivedBooks: state.archivedBooks,
          hasMoreActive: false,
          errorMessage: null,
        );
      } else {
        networkBooks = await _repository.getActiveBooks(
          page: 0,
          pageSize: _pageSize,
          search: requestQuery,
        );
        if (state.searchQuery != requestQuery) {
          _pendingSearchReload = true;
          return;
        }

        final serverIds = {for (var b in networkBooks) b.id};
        // Keep only cached books the server still lists as active, plus the
        // fresh search results.
        //
        // 搜索态下服务端会关闭 tag 聚合、直接返回扁平书单（连聚合行背后的
        // 成员书都会出现），因此这里不能保留缓存里的聚合行，否则同一批书
        // 会以「聚合卡片 + 逐本卡片」两种形态同时出现。
        final merged = [
          ...state.activeBooks.where((b) => serverIds.contains(b.id)),
          ...networkBooks,
        ];
        final finalActiveBooks = _dedupeByIdentity(merged);

        await _repository.saveBooksToCache(
          activeBooks: finalActiveBooks,
          archivedBooks: state.archivedBooks,
        );

        state = state.copyWith(
          isLoading: false,
          activeBooks: finalActiveBooks,
          archivedBooks: state.archivedBooks,
          hasMoreActive: networkBooks.length == _pageSize,
          errorMessage: null,
        );
      }

      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: true));
      // 书架里若出现 tag 聚合行且其成员书统计缺失，这里补算一次。
      unawaited(_warmSeriesStatsIfNeeded());
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    } finally {
      _isLoadingFromNetwork = false;
      if (_pendingSearchReload) {
        _pendingSearchReload = false;
        unawaited(
          state.showArchived
              ? _loadArchivedBooksFromNetwork()
              : _loadBooksFromNetwork(),
        );
      }
    }
  }

  Future<void> _loadArchivedBooksFromNetwork() async {
    if (_isLoadingFromNetwork) return;
    _isLoadingFromNetwork = true;
    final requestQuery = state.searchQuery;

    try {
      final settings = ref.read(settingsProvider);
      await _repository.contentService.setUserSetting(
        'stats_calc_sample_size',
        settings.statsCalcSampleSize.toString(),
      );

      _archivedPage = 0;
      final archived = await _repository.getArchivedBooks(
        page: 0,
        pageSize: _pageSize,
        search: requestQuery.isEmpty ? null : requestQuery,
      );
      if (state.searchQuery != requestQuery) {
        _pendingSearchReload = true;
        return;
      }
      final existingArchivedMap = {for (var b in state.archivedBooks) b.id: b};

      final mergedArchived = archived.map((networkBook) {
        final existing = existingArchivedMap[networkBook.id];
        if (existing != null) {
          final shouldUseNetworkStats =
              networkBook.hasStats &&
              (!existing.hasStats ||
                  networkBook.distinctTerms != null ||
                  networkBook.statusDistribution != null);
          return existing.copyWith(
            title: networkBook.title,
            language: networkBook.language,
            langId: existing.langId,
            totalPages: networkBook.totalPages,
            currentPage: networkBook.currentPage,
            percent: networkBook.percent,
            wordCount: networkBook.wordCount,
            distinctTerms:
                shouldUseNetworkStats && networkBook.distinctTerms != null
                ? networkBook.distinctTerms
                : existing.distinctTerms,
            unknownPct: shouldUseNetworkStats && networkBook.unknownPct != null
                ? networkBook.unknownPct
                : existing.unknownPct,
            statusDistribution:
                shouldUseNetworkStats && networkBook.statusDistribution != null
                ? networkBook.statusDistribution
                : existing.statusDistribution,
            tags: networkBook.tags,
            lastRead: networkBook.lastRead,
            isCompleted: networkBook.isCompleted,
            audioFilename: networkBook.audioFilename ?? existing.audioFilename,
            audioMetadataResolved:
                networkBook.audioMetadataResolved ||
                existing.audioMetadataResolved,
            lastStatsRefresh: shouldUseNetworkStats
                ? DateTime.now().millisecondsSinceEpoch
                : existing.lastStatsRefresh,
          );
        }
        return networkBook;
      }).toList();

      await _repository.saveBooksToCache(
        activeBooks: state.activeBooks,
        archivedBooks: mergedArchived,
      );

      state = state.copyWith(
        archivedBooks: mergedArchived,
        hasMoreArchived: archived.length == _pageSize,
        errorMessage: null,
      );

      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: false));
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      _isLoadingFromNetwork = false;
      if (_pendingSearchReload) {
        _pendingSearchReload = false;
        unawaited(
          state.showArchived
              ? _loadArchivedBooksFromNetwork()
              : _loadBooksFromNetwork(),
        );
      }
    }
  }

  Future<void> refreshBooks() async {
    if (_isLoadingFromNetwork) {
      return;
    }
    if (state.showArchived) {
      await _refreshArchived();
    } else {
      await _refreshActive();
    }
  }

  Future<void> _refreshActive() async {
    if (_isLoadingFromNetwork) {
      return;
    }
    _isLoadingFromNetwork = true;

    try {
      final settings = ref.read(settingsProvider);
      await _repository.contentService.setUserSetting(
        'stats_calc_sample_size',
        settings.statsCalcSampleSize.toString(),
      );

      // Full sync: replace the local active list with the server's active
      // books. The server excludes archived books, so books archived/frozen
      // on the server are removed from the list.
      final networkBooks = await _repository.getAllActiveBooks();
      final archived = state.archivedBooks;
      final finalActiveBooks = _mergeServerBooks(
        networkBooks,
        state.activeBooks,
      );

      await _repository.saveBooksToCache(
        activeBooks: finalActiveBooks,
        archivedBooks: archived,
      );

      state = state.copyWith(
        activeBooks: finalActiveBooks,
        hasMoreActive: false,
        errorMessage: null,
      );
      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: true));
      unawaited(_warmSeriesStatsIfNeeded());
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      _isLoadingFromNetwork = false;
    }
  }

  /// 书籍的唯一标识。
  ///
  /// 普通书用 BkID；tag 聚合行的 BkID 是 NULL（客户端容错后为 0），
  /// 多个聚合行会全部塌缩成同一个键 `book:0`，必须改用 tag 名区分。
  /// 同一个 tag 下的书如果跨语言，服务端会按 (tag, 语言) 各出一行
  /// （见 datatables.py 的 `GROUP BY st.seriestag, b.BkLgID`），
  /// 所以聚合行的键还要带上语言。
  String _bookIdentity(Book b) => b.isSeries
      ? 'series:${b.seriesTag}:${b.langId ?? b.language}'
      : 'book:${b.id}';

  /// 按 [_bookIdentity] 去重，保留首次出现的条目。
  ///
  /// 分页追加与搜索合并都可能重复塞入同一行，普通书靠 BkID 天然唯一，
  /// 但聚合行 id 全为 0，不去重就会出现多份同样的聚合卡片。
  List<Book> _dedupeByIdentity(Iterable<Book> books) {
    final seen = <String>{};
    final out = <Book>[];
    for (final b in books) {
      if (seen.add(_bookIdentity(b))) out.add(b);
    }
    return out;
  }

  /// Merges the server's authoritative active book list with locally cached
  /// books, preserving locally cached stats (distinctTerms, unknownPct,
  /// statusDistribution) for books that still exist on the server. Books
  /// missing from [serverBooks] (archived/deleted on the server) are dropped.
  List<Book> _mergeServerBooks(
    List<Book> serverBooks,
    List<Book> localBooks,
  ) {
    final existingMap = {for (var b in localBooks) _bookIdentity(b): b};
    return serverBooks.map((nb) {
      final existing = existingMap[_bookIdentity(nb)];
      if (existing == null) return nb;
      // 聚合行没有可继承的本地统计：它的词数/状态分布由服务端 SQL 聚合而来，
      // 而且所有聚合行 id 都是 0，按 id 匹配会互相串味（A 系列的统计跑到
      // B 系列卡片上）。直接用服务端的值。
      if (nb.isSeries) return nb;
      return existing.copyWith(
        title: nb.title,
        language: nb.language,
        langId: existing.langId ?? nb.langId,
        totalPages: nb.totalPages,
        currentPage: nb.currentPage,
        percent: nb.percent,
        wordCount: nb.wordCount,
        tags: nb.tags ?? existing.tags,
        lastRead: nb.lastRead ?? existing.lastRead,
        isCompleted: nb.isCompleted,
        audioFilename: nb.audioFilename ?? existing.audioFilename,
        audioMetadataResolved:
            nb.audioMetadataResolved || existing.audioMetadataResolved,
        distinctTerms: existing.distinctTerms,
        unknownPct: existing.unknownPct,
        statusDistribution: existing.statusDistribution,
      );
    }).toList();
  }

  Future<void> _refreshArchived() async {
    if (_isLoadingFromNetwork) {
      return;
    }
    _isLoadingFromNetwork = true;

    try {
      final settings = ref.read(settingsProvider);
      await _repository.contentService.setUserSetting(
        'stats_calc_sample_size',
        settings.statsCalcSampleSize.toString(),
      );

      final networkBooks = await _repository.getArchivedBooks();
      final active = state.activeBooks;

      // 用 _bookIdentity 而不是裸 id：归档列表里同样可能有 tag 聚合行，
      // 它们的 id 全是 0，按 id 判重会把所有聚合行误认为同一行。
      final existingArchivedKeys = {
        for (var b in state.archivedBooks) _bookIdentity(b),
      };
      final newArchivedBooks = networkBooks
          .where((b) => !existingArchivedKeys.contains(_bookIdentity(b)))
          .toList();

      final finalArchivedBooks = [...state.archivedBooks, ...newArchivedBooks];

      await _repository.saveBooksToCache(
        activeBooks: active,
        archivedBooks: finalArchivedBooks,
      );

      state = state.copyWith(
        archivedBooks: finalArchivedBooks,
        errorMessage: null,
      );
      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: false));
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      _isLoadingFromNetwork = false;
    }
  }

  void toggleArchivedFilter() {
    final newShowArchived = !state.showArchived;
    // Clear any lingering error so the filter chip can always switch back
    // to the other list (previously an archived-load failure left the screen
    // stuck on the ErrorDisplay).
    state = state.copyWith(showArchived: newShowArchived, errorMessage: null);

    if (newShowArchived &&
        state.archivedBooks.isEmpty &&
        !_isLoadingArchivedBooks) {
      _isLoadingArchivedBooks = true;
      _loadArchivedBooksFromNetwork().then((_) {
        _isLoadingArchivedBooks = false;
      });
    }

    // tag 过滤对 active / archived 两个列表分别生效（对应 web 端
    // /book/datatables/active 与 /book/datatables/Archived 各自的 filtTag），
    // 切换列表后要按新列表重新取一次。
    final tag = state.selectedTag;
    if (tag != null) {
      state = state.copyWith(tagFilterLoading: true);
      unawaited(_applyTagFilter(tag));
    }
  }

  /// 设置 tag 过滤（null/空串 = 清除）。
  ///
  /// 服务端语义：`filtTag` 非空时关闭 tag 聚合、返回精确匹配该 tag 的
  /// 扁平书单（lute/book/datatables.py 的 use_series_aggregation），
  /// 与 web 端点击 tag pill 过滤完全一致。
  Future<void> setTagFilter(String? tag) async {
    final normalized = (tag == null || tag.trim().isEmpty) ? null : tag.trim();
    if (state.selectedTag == normalized &&
        (normalized == null || state.tagFilteredBooks != null)) {
      return;
    }
    state = state.copyWith(
      selectedTag: normalized,
      tagFilteredBooks: null,
      tagFilterLoading: normalized != null,
      errorMessage: null,
    );
    if (normalized != null) {
      await _applyTagFilter(normalized);
    }
  }

  Future<void> _applyTagFilter(String tag) async {
    try {
      final books = await _repository.getBooksByTag(
        tag,
        archived: state.showArchived,
      );
      state = state.copyWith(
        tagFilteredBooks: books,
        tagFilterLoading: false,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(tagFilterLoading: false, errorMessage: e.toString());
    }
  }

  void setSearchQuery(String query) {
    if (state.searchQuery != query) {
      // 搜索与 tag 过滤互斥（v1 简化）：发起搜索时清掉 tag 过滤，
      // 避免两个不同来源的列表互相覆盖。
      if (query.isNotEmpty && state.selectedTag != null) {
        state = state.copyWith(
          selectedTag: null,
          tagFilteredBooks: null,
          tagFilterLoading: false,
        );
      }
      _activePage = 0;
      _archivedPage = 0;
      _pendingSearchReload = false;
      state = state.copyWith(
        isLoading: true,
        errorMessage: null,
        searchQuery: query,
        activeBooks: [],
        archivedBooks: [],
        hasMoreActive: true,
        hasMoreArchived: true,
      );
      if (_isLoadingFromNetwork) {
        _pendingSearchReload = true;
        return;
      }

      if (state.showArchived) {
        _loadArchivedBooksFromNetwork();
      } else {
        _loadBooksFromNetwork();
      }
    }
  }

  Future<void> loadMoreActiveBooks() async {
    if (_isLoadingMoreActive || !state.hasMoreActive) return;
    _isLoadingMoreActive = true;

    try {
      _activePage++;
      final newBooks = await _repository.getActiveBooks(
        page: _activePage,
        pageSize: _pageSize,
        search: state.searchQuery.isEmpty ? null : state.searchQuery,
      );

      final allBooks = _dedupeByIdentity([
        ...state.activeBooks,
        ...newBooks,
      ]);
      state = state.copyWith(
        activeBooks: allBooks,
        hasMoreActive: newBooks.length == _pageSize,
      );
      await _repository.saveBooksToCache(
        activeBooks: allBooks,
        archivedBooks: state.archivedBooks,
      );
      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: true));
    } catch (e) {
      _activePage--;
      ApiLogger.logError('loadMoreActiveBooks', e);
    } finally {
      _isLoadingMoreActive = false;
    }
  }

  Future<void> loadMoreArchivedBooks() async {
    if (_isLoadingMoreArchived || !state.hasMoreArchived) return;
    _isLoadingMoreArchived = true;

    try {
      _archivedPage++;
      final newBooks = await _repository.getArchivedBooks(
        page: _archivedPage,
        pageSize: _pageSize,
        search: state.searchQuery.isEmpty ? null : state.searchQuery,
      );

      final allBooks = _dedupeByIdentity([...state.archivedBooks, ...newBooks]);
      state = state.copyWith(
        archivedBooks: allBooks,
        hasMoreArchived: newBooks.length == _pageSize,
      );
      await _repository.saveBooksToCache(
        activeBooks: state.activeBooks,
        archivedBooks: allBooks,
      );
      unawaited(_resolveMissingAudioMetadataInBackground(activeBooks: false));
    } catch (e) {
      _archivedPage--;
      ApiLogger.logError('loadMoreArchivedBooks', e);
    } finally {
      _isLoadingMoreArchived = false;
    }
  }

  void clearError() {
    state = state.copyWith(errorMessage: null);
  }

  Future<void> updateBookInList(Book updatedBook) async {
    final isInActive = state.activeBooks.any((b) => b.id == updatedBook.id);
    if (isInActive) {
      final updatedActiveList = List<Book>.from(state.activeBooks);
      final activeIndex = state.activeBooks.indexWhere(
        (b) => b.id == updatedBook.id,
      );
      if (activeIndex != -1) {
        updatedActiveList[activeIndex] = updatedBook;
        state = state.copyWith(activeBooks: updatedActiveList);
      }
    } else {
      final updatedArchivedList = List<Book>.from(state.archivedBooks);
      final archivedIndex = state.archivedBooks.indexWhere(
        (b) => b.id == updatedBook.id,
      );
      if (archivedIndex != -1) {
        updatedArchivedList[archivedIndex] = updatedBook;
        state = state.copyWith(archivedBooks: updatedArchivedList);
      }
    }
  }

  Future<void> archiveBook(int bookId) async {
    try {
      await _repository.archiveBook(bookId);
      final bookToRemove = state.activeBooks.firstWhere(
        (b) => b.id == bookId,
        orElse: () => throw Exception('Book not found'),
      );
      final updatedArchivedBooks = [bookToRemove, ...state.archivedBooks];
      final updatedActiveBooks = state.activeBooks
          .where((b) => b.id != bookId)
          .toList();
      state = state.copyWith(
        activeBooks: updatedActiveBooks,
        archivedBooks: updatedArchivedBooks,
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> unarchiveBook(int bookId) async {
    try {
      await _repository.unarchiveBook(bookId);
      final bookToRestore = state.archivedBooks.firstWhere(
        (b) => b.id == bookId,
        orElse: () => throw Exception('Book not found'),
      );
      final updatedActiveBooks = [bookToRestore, ...state.activeBooks];
      final updatedArchivedBooks = state.archivedBooks
          .where((b) => b.id != bookId)
          .toList();
      state = state.copyWith(
        activeBooks: updatedActiveBooks,
        archivedBooks: updatedArchivedBooks,
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> deleteBook(int bookId) async {
    try {
      await _repository.deleteBook(bookId);
      final updatedActiveBooks = state.activeBooks
          .where((b) => b.id != bookId)
          .toList();
      final updatedArchivedBooks = state.archivedBooks
          .where((b) => b.id != bookId)
          .toList();

      await _repository.saveBooksToCache(
        activeBooks: updatedActiveBooks,
        archivedBooks: updatedArchivedBooks,
      );

      state = state.copyWith(
        activeBooks: updatedActiveBooks,
        archivedBooks: updatedArchivedBooks,
      );

      final settings = ref.read(settingsProvider);
      if (settings.currentBookId == bookId) {
        ref.read(settingsProvider.notifier).clearCurrentBook();
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<BookImportPreview> previewBookImportFromUrl(String importUrl) async {
    return await _repository.previewBookImportFromUrl(importUrl);
  }

  Future<int> createBook(BookCreateRequest request) async {
    final newBookId = await _repository.createBook(request);

    await loadBooks(forceRefresh: true, skipExpiredBookRefresh: true);

    return newBookId;
  }

  Future<BookEditFormData> getBookEditForm(int bookId) async {
    return await _repository.getBookEditForm(bookId);
  }

  Future<void> editBook(BookEditRequest request) async {
    await _repository.editBook(request);
    await loadBooks(forceRefresh: true, skipExpiredBookRefresh: true);
  }

  Future<void> invalidateCacheForBookLanguage(int bookId) async {
    final book = state.activeBooks.firstWhere(
      (b) => b.id == bookId,
      orElse: () => state.archivedBooks.firstWhere(
        (b) => b.id == bookId,
        orElse: () => throw Exception('Book not found'),
      ),
    );

    await _repository.invalidateLanguageCache(book.language);
  }

  /// 为 tag 聚合行背后「统计缺失或过期」的成员书补算统计。
  ///
  /// 被聚合隐藏的书不会作为独立行出现，客户端也就永远没机会为它们调
  /// `/book/table_stats`，聚合行的词数 / 状态分布会一直停在 0。
  /// 服务端为此在聚合行里回传 `SeriesStatsPending`（逗号分隔的成员书 id），
  /// 网页版据此批量补算；这里做同样的事，算完再重载一次让聚合值刷新。
  Future<void> _warmSeriesStatsIfNeeded() async {
    if (_isWarmingSeriesStats) return;

    final pending = <int>{};
    final seriesKeys = <String>{};
    for (final book in state.activeBooks) {
      if (!book.isSeries) continue;
      final ids = book.seriesStatsPending;
      if (ids == null || ids.isEmpty) continue;
      seriesKeys.add(_bookIdentity(book));
      pending.addAll(ids);
    }
    // 本会话已补算过的聚合行不再重复：万一某本书的统计服务端始终算不出来，
    // 不去重就会陷入「补算 → 重载 → 又发现待补算 → 再补算」的死循环。
    seriesKeys.removeAll(_seriesStatsWarmedSeries);
    if (seriesKeys.isEmpty || pending.isEmpty) return;

    _seriesStatsWarmedSeries.addAll(seriesKeys);
    _isWarmingSeriesStats = true;
    ApiLogger.logBackground(
      '_warmSeriesStatsIfNeeded',
      details: '${pending.length} member books, ${seriesKeys.length} series',
    );

    try {
      // 设上限，避免某个超大合集一次打出几百个请求。
      final ids = pending.take(120).toList();
      await Future.wait(
        ids.map((id) async {
          try {
            await _repository.contentService.getBookStats(
              id,
              timeout: const Duration(seconds: 20),
            );
          } catch (e) {
            ApiLogger.logError('_warmSeriesStatsIfNeeded($id)', e);
          }
        }),
      );
      // 聚合值是服务端 SQL 现算的，必须重新拉一次列表才会更新。
      await loadBooks(forceRefresh: true, skipExpiredBookRefresh: true);
    } catch (e) {
      ApiLogger.logError('_warmSeriesStatsIfNeeded', e);
    } finally {
      _isWarmingSeriesStats = false;
    }
  }

  Future<void> _resolveMissingAudioMetadataInBackground({
    required bool activeBooks,
  }) async {
    if (activeBooks) {
      if (_isResolvingActiveAudioMetadata) return;
      _isResolvingActiveAudioMetadata = true;
    } else {
      if (_isResolvingArchivedAudioMetadata) return;
      _isResolvingArchivedAudioMetadata = true;
    }

    try {
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sourceBooks = activeBooks ? state.activeBooks : state.archivedBooks;
      // 聚合行没有真实 BkID，解析音频元数据会打到 /book/edit/0 上，直接跳过。
      final unresolvedBooks = sourceBooks
          .where((book) => !book.isSeries && !book.audioMetadataResolved)
          .toList();

      if (unresolvedBooks.isEmpty) return;

      ApiLogger.logBackground(
        '_resolveMissingAudioMetadataInBackground',
        details:
            'target=${activeBooks ? 'active' : 'archived'}, count=${unresolvedBooks.length}',
      );

      final updatedBooks = List<Book>.from(sourceBooks);
      var changed = false;

      for (final book in unresolvedBooks) {
        final index = updatedBooks.indexWhere((item) => item.id == book.id);
        if (index == -1) {
          continue;
        }

        final resolvedBook = await _repository.resolveBookAudioMetadata(book);
        final previousBook = updatedBooks[index];
        if (resolvedBook.audioFilename != previousBook.audioFilename ||
            resolvedBook.audioMetadataResolved !=
                previousBook.audioMetadataResolved) {
          updatedBooks[index] = resolvedBook;
          changed = true;
        }
      }

      if (!changed) return;

      state = state.copyWith(
        activeBooks: activeBooks ? updatedBooks : state.activeBooks,
        archivedBooks: activeBooks ? state.archivedBooks : updatedBooks,
      );

      await _repository.saveBooksToCache(
        activeBooks: activeBooks ? updatedBooks : state.activeBooks,
        archivedBooks: activeBooks ? state.archivedBooks : updatedBooks,
      );
    } finally {
      if (activeBooks) {
        _isResolvingActiveAudioMetadata = false;
      } else {
        _isResolvingArchivedAudioMetadata = false;
      }
    }
  }
}

final booksRepositoryProvider = Provider<BooksRepository>((ref) {
  final contentService = ref.watch(contentServiceProvider);
  final cacheService = ref.watch(booksCacheServiceProvider);
  return BooksRepository(
    contentService: contentService,
    cacheService: cacheService,
  );
});

final booksProvider = NotifierProvider<BooksNotifier, BooksState>(() {
  return BooksNotifier();
});
