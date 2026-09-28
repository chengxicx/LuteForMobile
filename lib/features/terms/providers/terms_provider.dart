import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import '../../../core/logger/api_logger.dart';
import '../../../core/cache/providers/terms_list_cache_provider.dart';
import '../models/term.dart';
import '../models/term_stats.dart';
import '../repositories/terms_repository.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/providers/server_status_provider.dart';

@immutable
class TermsState {
  final bool isLoading;
  final List<Term> terms;
  final bool hasMore;
  final int currentPage;
  final String searchQuery;
  final int? selectedLangId;
  final Set<String?> selectedStatuses;
  final String? errorMessage;

  /// 上一次加载是「连不上服务端」而不是「服务端回了错」。
  ///
  /// 与书架的 BooksState.isOffline 同一约定：断网不是错误，界面上该显示一个
  /// 能自愈的 Offline 态，而不是把 `DioException [connection error]: ...`
  /// 原文拍给用户。它同时是自愈监听判断「要不要重载」的依据。
  final bool isOffline;
  final bool isInitialized;
  final TermStats stats;
  final bool isStatsLoading;
  final bool hasLoadedStats;
  final String? statsErrorMessage;

  const TermsState({
    this.isLoading = false,
    this.terms = const [],
    this.hasMore = true,
    this.currentPage = 0,
    this.searchQuery = '',
    this.selectedLangId,
    this.selectedStatuses = const {'1', '2', '3', '4', '5', '99'},
    this.errorMessage,
    this.isOffline = false,
    this.isInitialized = false,
    this.stats = TermStats.empty,
    this.isStatsLoading = false,
    this.hasLoadedStats = false,
    this.statsErrorMessage,
  });

  TermsState copyWith({
    bool? isLoading,
    List<Term>? terms,
    bool? hasMore,
    int? currentPage,
    String? searchQuery,
    int? selectedLangId,
    Set<String?>? selectedStatuses,
    String? errorMessage,
    bool? isOffline,
    bool? isInitialized,
    TermStats? stats,
    bool? isStatsLoading,
    bool? hasLoadedStats,
    String? statsErrorMessage,
  }) {
    return TermsState(
      isLoading: isLoading ?? this.isLoading,
      terms: terms ?? this.terms,
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      searchQuery: searchQuery ?? this.searchQuery,
      selectedLangId: selectedLangId ?? this.selectedLangId,
      selectedStatuses: selectedStatuses ?? this.selectedStatuses,
      errorMessage: errorMessage,
      isOffline: isOffline ?? this.isOffline,
      isInitialized: isInitialized ?? this.isInitialized,
      stats: stats ?? this.stats,
      isStatsLoading: isStatsLoading ?? this.isStatsLoading,
      hasLoadedStats: hasLoadedStats ?? this.hasLoadedStats,
      statsErrorMessage: statsErrorMessage,
    );
  }
}

class TermsNotifier extends Notifier<TermsState> {
  final int _pageSize = 20;
  bool _isLoadingMore = false;

  bool _status99LoadInProgress = false;
  int? _lastStatus99LangId;
  DateTime? _lastStatus99LoadTime;
  Timer? _status99DebounceTimer;

  /// [ServerStatusManager.addListener] 靠 `contains` 去重、靠同一个引用来
  /// remove，所以存成字段，而不是每次 build 现造一个闭包。
  late final void Function() _reachabilityListener = _onReachabilityChanged;

  @override
  TermsState build() {
    ref.listen(settingsProvider, (previous, next) {
      if (previous?.serverUrl != next.serverUrl) {
        _onServerChanged();
      }
      if (previous?.currentBookLangId != next.currentBookLangId) {
        _onLangIdChanged();
      }
    });

    // 服务端恢复可达时自愈：上一次加载要是被「断网短路」跳过过，现在补一次。
    // 没有这个监听，用户出了地铁只能看着一个 Offline 页。
    ServerStatusManager.addListener(_reachabilityListener);
    ref.onDispose(
      () => ServerStatusManager.removeListener(_reachabilityListener),
    );

    return const TermsState();
  }

  /// 服务端从不可达恢复可达时的自愈入口（同 BooksNotifier 的约定）。
  void _onReachabilityChanged() {
    if (!ServerStatusManager.isReachable) return;
    if (!state.isOffline) return;

    Future.microtask(() {
      if (!state.isOffline) return;
      unawaited(refreshTerms());
    });
  }

  /// 判断「加载失败」属于哪一类，和 BooksNotifier.classifyLoadFailure 同一
  /// 约定：拦截器判定服务端不可达时会 `markError()`，标志为假 = 根本没连上
  /// → 记成可自愈的 Offline 态；标志为真 = 服务器真的回了错 → 才把
  /// `e.toString()` 显示出来。纯函数，好让这条约定能被单测锁住。
  @visibleForTesting
  static (String?, bool) classifyLoadFailure({
    required Object error,
    required bool serverReachable,
  }) {
    if (serverReachable) return (error.toString(), false);
    return (null, true);
  }

  Future<void> _onServerChanged() async {
    state = state.copyWith(isInitialized: false);
    // 换服务器后旧快照全部作废，否则会把 A 服务器的词展示成 B 服务器的现状。
    await ref.read(termsListCacheServiceProvider).clearAll();
    await loadTerms(reset: true);
  }

  Future<void> _onLangIdChanged() async {
    state = state.copyWith(isInitialized: false, errorMessage: null);
    await loadTerms(reset: true);
  }

  Future<void> loadTerms({bool reset = true}) async {
    if (reset) {
      state = state.copyWith(
        isLoading: true,
        terms: [],
        currentPage: 0,
        hasMore: true,
        errorMessage: null,
        isOffline: false,
      );
    }

    final repository = ref.read(termsRepositoryProvider);
    final cacheService = ref.read(termsListCacheServiceProvider);

    if (!repository.contentService.isConfigured) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Server URL not configured.',
      );
      return;
    }

    try {
      int? langId = state.selectedLangId;

      if (!state.isInitialized) {
        final currentBookLangId = ref.read(settingsProvider).currentBookLangId;
        state = state.copyWith(
          selectedLangId: currentBookLangId,
          isInitialized: true,
        );
        langId = currentBookLangId;
      }

      final filteredStatuses = state.selectedStatuses
          .whereType<String>()
          .toSet();

      print(
        'DEBUG loadTerms: langId=$langId, search="${state.searchQuery}", statuses=$filteredStatuses',
      );

      // 缓存先行：本地已有的词条先显示出来，断网不是把它藏起来的理由。
      // 追加加载（reset=false）不读缓存 —— 要往现有列表后面拼新一页。
      if (reset) {
        final cached = await cacheService.getTerms(
          langId: langId,
          search: state.searchQuery,
          statuses: filteredStatuses,
        );
        if (cached != null && cached.isNotEmpty) {
          state = state.copyWith(isLoading: false, terms: cached);
        } else {
          state = state.copyWith(isLoading: false);
        }
      }

      // 不可达时跳过网络（书架同款短路）：这一次请求只会在 ApiRequestQueue
      // 里挂到 requestDeadline（30 秒）超时，然后把一坨 DioException 拍到
      // 屏幕上。给出可自愈的 Offline 态，网络恢复后自愈监听会重载。
      if (!ServerStatusManager.isReachable) {
        state = state.copyWith(isLoading: false, isOffline: true);
        return;
      }

      final newTerms = await repository.getTermsPaginated(
        langId: langId,
        search: state.searchQuery.isNotEmpty ? state.searchQuery : null,
        page: state.currentPage,
        pageSize: _pageSize,
        selectedStatuses: filteredStatuses.isEmpty ? null : filteredStatuses,
      );

      state = state.copyWith(
        isLoading: false,
        terms: reset ? newTerms : [...state.terms, ...newTerms],
        currentPage: state.currentPage + 1,
        hasMore: newTerms.length == _pageSize,
        errorMessage: null,
        isOffline: false,
      );

      // 成功后写快照（追加加载存合并后的整份列表），断网时原样恢复这一屏。
      unawaited(
        cacheService.saveTerms(
          state.terms,
          langId: langId,
          search: state.searchQuery,
          statuses: filteredStatuses,
        ),
      );

      if (langId != null && reset) {
        if (ref.read(settingsProvider).showTermStatsCard) {
          loadStats(langId);
        }
      }
    } catch (e) {
      ApiLogger.logError('loadTerms', e);
      final (message, offline) = classifyLoadFailure(
        error: e,
        serverReachable: ServerStatusManager.isReachable,
      );
      state = state.copyWith(
        isLoading: false,
        errorMessage: message,
        isOffline: offline,
      );
    }
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !state.hasMore) return;
    _isLoadingMore = true;
    await loadTerms(reset: false);
    _isLoadingMore = false;
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
    loadTerms(reset: true);
  }

  void setLanguageFilter(int? langId) {
    state = state.copyWith(selectedLangId: langId);
    loadTerms(reset: true);
    if (langId != null) {
      if (ref.read(settingsProvider).showTermStatsCard) {
        loadStats(langId);
      }
    }
  }

  Future<void> loadStats(int langId, {bool force = false}) async {
    final settings = ref.read(settingsProvider);
    if (!settings.showTermStatsCard) {
      return;
    }
    if (!force && !settings.autoLoadTermStatsCards) {
      return;
    }

    state = state.copyWith(isStatsLoading: true, statsErrorMessage: null);
    try {
      final repository = ref.read(termsRepositoryProvider);
      final stats = await repository.getTermStats(langId);
      state = state.copyWith(
        stats: stats,
        isStatsLoading: false,
        hasLoadedStats: true,
        statsErrorMessage: null,
      );
    } catch (e) {
      ApiLogger.logError('loadStats', e);
      state = state.copyWith(
        isStatsLoading: false,
        statsErrorMessage: e.toString(),
      );
    }
  }

  Future<void> loadStatus99Only(int langId) async {
    if (!ref.read(settingsProvider).autoLoadTermStatsCards) {
      return;
    }

    _status99DebounceTimer?.cancel();
    _status99DebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _executeLoadStatus99(langId);
    });
  }

  Future<void> _executeLoadStatus99(int langId) async {
    final now = DateTime.now();
    if (_status99LoadInProgress) {
      return;
    }
    if (_lastStatus99LangId == langId &&
        _lastStatus99LoadTime != null &&
        now.difference(_lastStatus99LoadTime!).inSeconds < 3) {
      return;
    }

    _status99LoadInProgress = true;
    try {
      final repository = ref.read(termsRepositoryProvider);
      final count = await repository.contentService.getTermCount(
        langId: langId,
        statusMin: 99,
        statusMax: 99,
      );

      final currentStats = state.stats;
      final newStats = TermStats(
        status1: currentStats.status1,
        status2: currentStats.status2,
        status3: currentStats.status3,
        status4: currentStats.status4,
        status5: currentStats.status5,
        status99: count,
        total:
            currentStats.status1 +
            currentStats.status2 +
            currentStats.status3 +
            currentStats.status4 +
            currentStats.status5 +
            count,
      );
      state = state.copyWith(
        stats: newStats,
        hasLoadedStats: true,
        statsErrorMessage: null,
      );

      _lastStatus99LangId = langId;
      _lastStatus99LoadTime = DateTime.now();
    } catch (e) {
      ApiLogger.logError('loadStatus99Only', e);
    } finally {
      _status99LoadInProgress = false;
    }
  }

  void setStatusFilter(String? status) {
    final newStatuses = Set<String?>.from(state.selectedStatuses);
    if (status == null) {
      final allDefaultSelected = {
        '1',
        '2',
        '3',
        '4',
        '5',
        '99',
      }.every((s) => newStatuses.contains(s));
      if (allDefaultSelected) {
        newStatuses.clear();
      } else {
        newStatuses.addAll(['1', '2', '3', '4', '5', '99']);
      }
    } else {
      if (newStatuses.contains(status)) {
        newStatuses.remove(status);
      } else {
        newStatuses.add(status);
      }
    }
    state = state.copyWith(selectedStatuses: newStatuses);
    loadTerms(reset: true);
  }

  void clearStatuses() {
    state = state.copyWith(
      selectedStatuses: const {'1', '2', '3', '4', '5', '99'},
    );
    loadTerms(reset: true);
  }

  Future<void> deleteTerm(int termId) async {
    try {
      final repository = ref.read(termsRepositoryProvider);
      await repository.deleteTerm(termId);
      state = state.copyWith(
        terms: state.terms.where((t) => t.id != termId).toList(),
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  void updateTermInList(Term updatedTerm) {
    final updatedTerms = state.terms.map((term) {
      if (term.id == updatedTerm.id) {
        return updatedTerm;
      }
      return term;
    }).toList();
    state = state.copyWith(terms: updatedTerms);
  }

  Future<void> refreshTerms() async {
    await loadTerms(reset: true);
  }
}

final termsProvider = NotifierProvider<TermsNotifier, TermsState>(() {
  return TermsNotifier();
});
