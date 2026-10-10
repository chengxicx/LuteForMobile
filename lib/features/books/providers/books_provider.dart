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
import '../../../core/cache/providers/book_progress_provider.dart';
import '../../../core/cache/providers/books_cache_provider.dart';
import '../../../shared/providers/server_status_provider.dart';

@immutable
class BooksState {
  final bool isLoading;
  final bool isRefreshing;
  final List<Book> activeBooks;
  final List<Book> archivedBooks;
  final bool showArchived;
  final String? errorMessage;

  /// 上一次加载是「连不上服务端」而不是「服务端回了错」。
  ///
  /// 和 [errorMessage] 分开是有意的：断网不是错误，界面上该显示一个能自愈的
  /// Offline 态，而不是把 `DioException [connection error]: ...` 原文拍给用户。
  /// 它同时是 `BooksNotifier._onReachabilityChanged` 判断「要不要自愈重载」
  /// 的依据。
  final bool isOffline;

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
    this.isOffline = false,
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
    Object? errorMessage = _unset,
    bool? isOffline,
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
      // 必须用哨兵：`errorMessage ?? this.errorMessage` 会让「传 null 表示清空」
      // 和「没传」变成同一件事，于是 errorMessage 一旦被写上就再也清不掉 ——
      // 表现是书架断网一次之后永远停在错误页，即使重试请求已经 200 拿回了书目。
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
      isOffline: isOffline ?? this.isOffline,
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

  /// [ServerStatusManager.addListener] 靠 `contains` 去重、靠同一个引用来
  /// remove，所以存成字段，而不是每次 build 现造一个闭包。
  late final void Function() _reachabilityListener = _onReachabilityChanged;

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

    // 服务端恢复可达时自愈：上一次加载确实是因为断网被短路掉过，现在补一次。
    // 没有这个监听，用户出了地铁只能看着一个 Offline 页，而且他不会想到
    // 需要下拉刷新一下。（build 可能重跑，onDispose 会先摘掉旧监听。）
    ServerStatusManager.addListener(_reachabilityListener);
    ref.onDispose(
      () => ServerStatusManager.removeListener(_reachabilityListener),
    );

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

    // 重建（依赖的 settings 变了，比如 reader 打开书时的 updateCurrentBook）
    // 不能返回空 state：那会把书架清空，下一次进书架只能靠缓存恢复，
    // notifyBookOpened 这类「打开书瞬间」的后台调用读到的也是空列表而空转
    // —— 2026-10-11 手机实测因此失效。Riverpod 重建沿用同一个 notifier
    // 实例，stateOrNull 给出重建前的状态；首次 build 尚未初始化 → 从空开始。
    return stateOrNull ?? const BooksState();
  }

  /// 服务端从不可达恢复可达时的自愈入口。
  ///
  /// 只在「上一次加载确实是因为断网被短路掉」的时候重来 —— 否则每次网络抖动
  /// 都会触发一次全量同步。这里不碰 widget，只是把 [loadBooks] 排到当前调用栈
  /// 之后：本回调由 Dio 拦截器/请求队列触发（不在 build 期间），但同步改 state
  /// 仍有重入风险，microtask 更稳妥。
  void _onReachabilityChanged() {
    if (!ServerStatusManager.isReachable) return;
    if (!state.isOffline) return;
    if (_isLoadingBooks) return;

    Future.microtask(() {
      if (!state.isOffline) return;
      // 自愈重载跟随当前标签：loadBooks 只走 active 的网络同步，屏幕停在
      // Archived 标签时归档列表会停在「No books found.」（归档缓存非空时
      // 不受影响，loadBooks 会从缓存恢复；这里修的是「从没在线看过归档 →
      // 断网切过去 → 再联网」的窄边界）。
      if (state.showArchived) {
        unawaited(_loadArchivedBooksFromNetwork());
      } else {
        unawaited(loadBooks(forceRefresh: true));
      }
    });
  }

  /// [BooksState.isOffline] 与 `errorMessage` 该填什么，取决于失败属于哪一类。
  ///
  /// 纯函数，好让这条「断网不该报 DioException」的约定能被单测锁住。
  @visibleForTesting
  static (String?, bool) classifyLoadFailure({
    required Object error,
    required bool serverReachable,
  }) {
    if (serverReachable) return (error.toString(), false);
    // 连不上服务端：不显示错误原文，改成一个可自愈的离线态。
    return (null, true);
  }

  /// 把一次「加载失败」写进 state。
  ///
  /// 借 `ServerStatusManager.isReachable` 区分两类失败：拦截器判定服务端不可达
  /// 时会 `markError()`，所以标志为假 =「根本没连上」→ 记成 [BooksState.isOffline]
  /// （一个可自愈的离线态）；标志为真 =「服务器真的回了错」→ 才把 `e.toString()`
  /// 显示出来。把 `DioException [connection error]: null` 原文拍在屏幕上对用户
  /// 没有意义，他只会以为自己弄坏了什么。
  ///
  /// 注意这个标志只对连接类失败为假：健康探测通过时 `onError` 走 `handler.next`，
  /// 标志不动。
  ///
  /// 需要顺手复位某个标志的调用点（isLoading / isRefreshing / tagFilterLoading）
  /// 通过具名参数传进来，避免各处各写一份 copyWith 而漏掉分类。
  void _recordLoadFailure(
    Object e, {
    bool? isLoading,
    bool? isRefreshing,
    bool? tagFilterLoading,
  }) {
    final (message, offline) = classifyLoadFailure(
      error: e,
      serverReachable: ServerStatusManager.isReachable,
    );
    state = state.copyWith(
      isLoading: isLoading,
      isRefreshing: isRefreshing,
      tagFilterLoading: tagFilterLoading,
      errorMessage: message,
      isOffline: offline,
    );
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
    state = state.copyWith(
      isLoading: !hasBooksToShow,
      errorMessage: null,
      isOffline: false,
    );

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

      // 不可达时这一次请求只会在 ApiRequestQueue 里挂到 requestDeadline
      // （30 秒）超时，然后把一坨 DioException 拍到屏幕上 —— 而且 _buildBody
      // 先判 errorMessage，那坨东西还会盖住刚刚显示出来的缓存书。所以直接
      // 跳过网络，给出可自愈的 Offline 态。
      //
      // 位置必须在读缓存之后：本地已有的书目在任何情况下都要先显示出来，
      // 断网不是把它藏起来的理由。
      if (!ServerStatusManager.isReachable) {
        state = state.copyWith(isOffline: true);
        return;
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

  /// Reader 打开了一本书：把「最新阅读」排序的变化**预先**应用到书架。
  ///
  /// 服务端在 `/read/start_reading` 时把 text.start_date 更新为现在，书单
  /// 默认按 LastOpenedDate 降序返回（lute/book/datatables.py 的默认排序）。
  /// 这意味着刚读的书在**下一次**书架网络同步时必然跳到顶部——如果不在
  /// 读的时候先本地落好位，用户从阅读页切回 Books 时就会眼看着列表重排：
  /// 先渲染缓存旧序，同步回来再跳成新序。
  ///
  /// 这里做的是服务端排序结果的本地预演：书插到「已打开」组最前（从未
  /// 打开过的书仍排其上，对应服务端 `LastOpenedDate is null desc`）、
  /// lastRead 打上与服务端同格式的时间戳（[Book.lastReadStampNow]），
  /// 然后写回缓存。下次进书架：缓存恢复即新序，同步回来的顺序与之一致，
  /// 列表纹丝不动。
  ///
  /// Book Set 聚合行把成员书藏在列表之外（扁平分支拿不到它们），所以开
  /// 的若是成员书，按 [openedBook] 的 tag 找到对应聚合行预排——聚合行的
  /// LastOpenedDate 取成员书最大值，成员书一读它就跳顶，用户的书架顶部
  /// 恰恰全是聚合行（2026-10-11 手机实测）。
  ///
  /// 搜索态不预演：此时 activeBooks 是搜索结果而非全量书单，重排会污染它。
  void notifyBookOpened(int bookId, {Book? openedBook}) {
    if (state.searchQuery.isNotEmpty) return;

    final stamp = Book.lastReadStampNow();
    var active = reorderAfterOpened(state.activeBooks, bookId, stamp);
    final archived = reorderAfterOpened(state.archivedBooks, bookId, stamp);

    // 书不在顶层列表（聚合行成员书）：按 tag 匹配聚合行。普通书若在列表里
    // 就不可能同时属于聚合行（服务端对配置成 Book Set 的 tag 关闭扁平返回）。
    if (identical(active, state.activeBooks) && openedBook != null) {
      active = reorderSeriesAfterOpened(
        state.activeBooks,
        {
          if (openedBook.tags != null) ...openedBook.tags!,
          if (openedBook.seriesTag != null) openedBook.seriesTag!,
        },
        stamp,
        langId: openedBook.langId,
      );
    }

    // 返回同一实例 = 没有变化（书不在列表里/聚合行/已在目标位置），
    // 不要为没有视觉影响的重排白白刷一次状态和缓存。
    if (identical(active, state.activeBooks) &&
        identical(archived, state.archivedBooks)) {
      return;
    }

    state = state.copyWith(activeBooks: active, archivedBooks: archived);

    // 缓存写失败只影响下次进书架的第一帧（恢复出旧序，同步回来照旧跳一次），
    // 不影响本次显示，所以后台重试与否都无关紧要，记条日志即可。
    () async {
      try {
        await _repository.saveBooksToCache(
          activeBooks: active,
          archivedBooks: archived,
        );
      } catch (e) {
        ApiLogger.logError('notifyBookOpened', e);
      }
    }();
  }

  /// [notifyBookOpened] 的纯函数实现：把刚打开的书重排到服务端下次会
  /// 返回的位置，返回 [books] 实例本身表示无需变化。
  ///
  /// 服务端默认排序是「从未打开过的书排最前，其余按最后打开时间降序」
  /// （datatables.py 把 LastOpenedDate 的排序键替换成
  /// `LastOpenedDate is null desc, LastOpenedDate`）。刚打开的书是
  /// 「已打开」组里最新的，所以插入点是第一个 lastRead 非空的条目。
  @visibleForTesting
  static List<Book> reorderAfterOpened(
    List<Book> books,
    int bookId,
    String stamp,
  ) {
    final index = books.indexWhere((b) => b.id == bookId);
    if (index == -1) return books;
    final book = books[index];
    // 聚合行的 id 全为 0（BkID NULL 的容错值），真书不可能 <= 0；
    // 两者都不是「被打开的那本」。
    if (book.isSeries || book.id <= 0) return books;

    return _insertAtOpenedPosition(books, index, book, stamp);
  }

  /// [reorderAfterOpened] 的聚合行版本：刚打开的是某 Book Set 的成员书，
  /// 按 tag 找到对应聚合行重排。服务端对同一 tag 按语言各出一行，优先匹配
  /// [langId] 相同的那行。
  @visibleForTesting
  static List<Book> reorderSeriesAfterOpened(
    List<Book> books,
    Set<String> seriesTags,
    String stamp, {
    int? langId,
  }) {
    if (seriesTags.isEmpty) return books;
    bool matches(Book b) =>
        b.isSeries &&
        b.seriesTag != null &&
        b.seriesTag!.isNotEmpty &&
        seriesTags.contains(b.seriesTag);
    var index = books.indexWhere(
      (b) => matches(b) && langId != null && b.langId == langId,
    );
    if (index == -1) {
      index = books.indexWhere(matches);
    }
    if (index == -1) return books;

    return _insertAtOpenedPosition(books, index, books[index], stamp);
  }

  /// 把 [books] 里 [index] 处的书摘出来、打上 [stamp]，再插回「已打开」组
  /// 最前（[reorderAfterOpened] 的注释说明了这个位置的依据）。
  ///
  /// 已在目标位置且本来就有 lastRead 的书原样返回同一实例——lastRead 为
  /// null 的书即使位置凑巧相同也要补上时间戳，否则它会一直显示 "Never"
  /// 直到下次同步。
  static List<Book> _insertAtOpenedPosition(
    List<Book> books,
    int index,
    Book book,
    String stamp,
  ) {
    final rest = List<Book>.from(books)..removeAt(index);
    final insertAt = rest.indexWhere((b) => b.lastRead != null);
    final target = insertAt == -1 ? rest.length : insertAt;
    if (book.lastRead != null && index == target) return books;

    return List<Book>.from(rest)
      ..insert(target, book.copyWith(lastRead: stamp));
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
          noQueue: true,
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
          _recordLoadFailure(e, isRefreshing: false);
        }
        rethrow;
      } finally {
        try {
          final settings = ref.read(settingsProvider);
          await _repository.contentService.setUserSetting(
            'stats_calc_sample_size',
            settings.statsCalcSampleSize.toString(),
            noQueue: true,
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
        noQueue: true,
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
          noQueue: true,
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
        noQueue: true,
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
      _recordLoadFailure(e, isLoading: false);
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
        noQueue: true,
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
      _recordLoadFailure(e);
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
        noQueue: true,
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
      _recordLoadFailure(e);
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
        noQueue: true,
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
      _recordLoadFailure(e);
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
      _recordLoadFailure(e, tagFilterLoading: false);
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
      _recordLoadFailure(e);
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
      _recordLoadFailure(e);
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

      // The book is gone server-side, so its remembered page is dead
      // weight -- drop it here rather than leaving a record that can
      // never resolve to a cached page.
      await ref.read(bookProgressServiceProvider).removeBook(bookId);

      final settings = ref.read(settingsProvider);
      if (settings.currentBookId == bookId) {
        ref.read(settingsProvider.notifier).clearCurrentBook();
      }
    } catch (e) {
      _recordLoadFailure(e);
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
