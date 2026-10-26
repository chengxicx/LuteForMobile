import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dictionary_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/dict/dict_repository.dart';
import '../../settings/models/ai_settings.dart';
import '../../settings/providers/ai_settings_provider.dart';
import '../../../core/providers/ai_provider.dart';
import '../providers/current_book_provider.dart';
import '../../../shared/providers/network_providers.dart';
import '../../../shared/theme/theme_extensions.dart';

enum DictionaryTabType { dictionary, ai }

enum AITabType { translation, virtualDictionary }

class DictionaryView extends ConsumerStatefulWidget {
  final String term;

  /// 词条读音；本机词典里很多词条是按假名读音建键的，带上它能命中更多。
  final String? reading;
  final String? sentence;
  final List<DictionarySource> dictionaries;
  final int languageId;
  final VoidCallback onClose;
  final bool isVisible;
  final DictionaryService dictionaryService;
  final void Function(String)? onAddAITranslation;

  const DictionaryView({
    super.key,
    required this.term,
    this.reading,
    this.sentence,
    required this.dictionaries,
    required this.languageId,
    required this.onClose,
    required this.isVisible,
    required this.dictionaryService,
    this.onAddAITranslation,
  });

  @override
  ConsumerState<DictionaryView> createState() => _DictionaryViewState();
}

class _DictionaryViewState extends ConsumerState<DictionaryView> {
  late PageController _pageController;
  int _currentPage = 0;
  final Map<int, InAppWebViewController> _webviewControllers = {};
  bool _hasLoaded = false;
  DictionaryTabType _currentTab = DictionaryTabType.dictionary;
  AITabType _currentAITab = AITabType.translation;
  String? _aiTranslation;
  String? _aiErrorMessage;
  bool _isLoadingAI = false;
  bool _hasFetchedAI = false;
  String? _virtualDictionaryContent;
  String? _virtualDictionaryError;
  bool _isLoadingVirtualDict = false;
  bool _hasFetchedVirtualDict = false;
  final Set<int> _preloadedPages = {};
  bool _isPreloading = false;
  bool _loginNoticeShown = false;

  /// 本地词典（服务器词典池里那几本）在本机池里的查询结果，按 page index。
  /// 命中就直接渲染文本，不再请求服务器——断网也能看。
  Map<int, PoolLookupResult> _localLookups = const {};
  bool _localLookupsDone = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _loadInitialPage();
    _resolveLocalLookups();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialPage() async {
    if (!mounted) return;

    final lastUsed = await widget.dictionaryService.getLastUsedDictionary(
      widget.languageId,
    );

    if (!mounted) return;

    if (lastUsed != null && widget.dictionaries.isNotEmpty) {
      final index = widget.dictionaries.indexWhere((d) => d.name == lastUsed);
      if (index >= 0) {
        setState(() {
          _currentPage = index;
        });
        _pageController.dispose();
        _pageController = PageController(initialPage: index);
      }
    }

    setState(() {
      _hasLoaded = true;
    });
  }

  /// 先把"本地词典"在本机池里查一遍，决定每页是本地渲染还是回落服务器。
  ///
  /// 设置页把池里的 `.db` 下载到本机后，查词完全不需要网络：词典键查询是
  /// 毫秒级的。以前这里一律走服务器 `/read/localdict`（把渲染好的 HTML 塞进
  /// WebView），断网或服务端抖动时就是一块黑屏 / Cloudflare 错误页。
  Future<void> _resolveLocalLookups() async {
    final localIndexes = <int>[
      for (var i = 0; i < widget.dictionaries.length; i++)
        if (widget.dictionaries[i].isLocalDictionary) i,
    ];
    if (localIndexes.isEmpty) return;

    final repo = ref.read(dictRepositoryProvider);
    final results = <int, PoolLookupResult>{};
    for (final i in localIndexes) {
      try {
        results[i] = await repo.lookupInPool(
          filename: widget.dictionaries[i].urlTemplate,
          term: widget.term,
          reading: widget.reading,
        );
      } catch (_) {
        results[i] = const PoolLookupResult(available: false);
      }
    }

    if (!mounted) return;
    setState(() {
      _localLookups = results;
      _localLookupsDone = true;
    });
  }

  bool _shouldShowAITab() {
    final aiSettings = ref.watch(aiSettingsProvider);
    final provider = aiSettings.provider;
    final termConfig = aiSettings.promptConfigs[AIPromptType.termTranslation];
    return provider != AIProvider.none && termConfig?.enabled == true;
  }

  bool _shouldShowVirtualDictionary() {
    final aiSettings = ref.watch(aiSettingsProvider);
    final provider = aiSettings.provider;
    final virtualDictConfig =
        aiSettings.promptConfigs[AIPromptType.termExplanation];
    return provider != AIProvider.none && virtualDictConfig?.enabled == true;
  }

  Future<void> _fetchAITranslation() async {
    if (_isLoadingAI || _hasFetchedAI) return;

    setState(() {
      _isLoadingAI = true;
      _aiTranslation = null;
      _aiErrorMessage = null;
    });

    try {
      final aiService = ref.read(aiServiceProvider);
      final currentBookState = ref.read(currentBookProvider);
      final language =
          currentBookState.languageName ??
          currentBookState.book?.language ??
          'Unknown';

      final translation = await aiService.translateTerm(
        widget.term,
        language,
        sentence: widget.sentence,
      );

      if (mounted) {
        setState(() {
          _isLoadingAI = false;
          _aiTranslation = translation;
          _hasFetchedAI = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAI = false;
          _aiErrorMessage = e.toString();
          _hasFetchedAI = true;
        });
      }
    }
  }

  Future<void> _fetchMoreAITranslations() async {
    if (_isLoadingAI) return;
    if (_aiTranslation == null || _aiTranslation!.trim().isEmpty) return;

    setState(() {
      _isLoadingAI = true;
      _aiErrorMessage = null;
    });

    try {
      final aiService = ref.read(aiServiceProvider);
      final currentBookState = ref.read(currentBookProvider);
      final language =
          currentBookState.languageName ??
          currentBookState.book?.language ??
          'Unknown';

      final moreTranslations = await aiService.translateTermMore(
        widget.term,
        language,
        sentence: widget.sentence,
        existingTranslations: _aiTranslation!,
      );

      if (!mounted) return;

      final mergedTranslations = _mergeDistinctTranslations(
        _aiTranslation!,
        moreTranslations,
      );

      final foundNewTranslations = mergedTranslations != _aiTranslation!;

      setState(() {
        _isLoadingAI = false;
        _aiTranslation = mergedTranslations;
        _hasFetchedAI = true;
      });

      if (mounted && !foundNewTranslations) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No new distinct translations found'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAI = false;
          _aiErrorMessage = e.toString();
        });
      }
    }
  }

  String _mergeDistinctTranslations(String current, String incoming) {
    final currentItems = _splitTranslations(current);
    final merged = List<String>.from(currentItems);
    final seen = currentItems.map((item) => item.toLowerCase()).toSet();

    for (final item in _splitTranslations(incoming)) {
      final normalized = item.toLowerCase();
      if (normalized == 'none' || seen.contains(normalized)) {
        continue;
      }
      merged.add(item);
      seen.add(normalized);
    }

    return merged.join(', ');
  }

  List<String> _splitTranslations(String raw) {
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Future<void> _fetchVirtualDictionary() async {
    if (_isLoadingVirtualDict || _hasFetchedVirtualDict) return;

    setState(() {
      _isLoadingVirtualDict = true;
      _virtualDictionaryContent = null;
      _virtualDictionaryError = null;
    });

    try {
      final aiService = ref.read(aiServiceProvider);
      final currentBookState = ref.read(currentBookProvider);
      final language = currentBookState.languageName ?? 'Unknown';

      final content = await aiService.getTermExplanation(
        widget.term,
        language,
        sentence: widget.sentence,
      );

      if (mounted) {
        setState(() {
          _isLoadingVirtualDict = false;
          _virtualDictionaryContent = content;
          _hasFetchedVirtualDict = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingVirtualDict = false;
          _virtualDictionaryError = e.toString();
          _hasFetchedVirtualDict = true;
        });
      }
    }
  }

  void _handleAddToTranslation(String translation) {
    if (translation.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No AI translation available'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (widget.onAddAITranslation == null) return;

    final cleanTranslation = translation.replaceAll('\n', ' ');
    widget.onAddAITranslation!(cleanTranslation);
  }

  Future<void> _preloadAdjacentPages() async {
    if (_isPreloading || !mounted || widget.dictionaries.isEmpty) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 200));

    if (!mounted || !widget.isVisible) {
      return;
    }

    _isPreloading = true;

    final pagesToPreload = <int>[];

    if (_currentPage > 0 && !_preloadedPages.contains(_currentPage - 1)) {
      pagesToPreload.add(_currentPage - 1);
    }

    if (_currentPage < widget.dictionaries.length - 1 &&
        !_preloadedPages.contains(_currentPage + 1)) {
      pagesToPreload.add(_currentPage + 1);
    }

    if (pagesToPreload.isEmpty) {
      _isPreloading = false;
      return;
    }

    for (final pageIndex in pagesToPreload) {
      if (!mounted) break;

      try {
        _pageController.jumpToPage(pageIndex);
        _preloadedPages.add(pageIndex);

        if (!mounted) break;

        _pageController.jumpToPage(_currentPage);
      } catch (e) {
        if (kDebugMode) {
          print('Error preloading page $pageIndex: $e');
        }
      }
    }

    _isPreloading = false;
  }

  @override
  Widget build(BuildContext context) {
    final shouldShowAITab = _shouldShowAITab();
    final shouldShowVirtualDict = _shouldShowVirtualDictionary();

    if (widget.dictionaries.isEmpty && !shouldShowAITab) {
      return _buildEmptyState(context);
    }

    if (!_hasLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (shouldShowAITab && _currentTab == DictionaryTabType.ai) {
      if (_currentAITab == AITabType.translation && !_hasFetchedAI) {
        _fetchAITranslation();
      } else if (_currentAITab == AITabType.virtualDictionary &&
          !_hasFetchedVirtualDict) {
        _fetchVirtualDictionary();
      }
    }

    return Column(
      children: [
        _buildTabHeader(context, shouldShowAITab, shouldShowVirtualDict),
        const SizedBox(height: 8),
        Expanded(
          child: shouldShowAITab
              ? _buildTabContent(context, shouldShowVirtualDict)
              : _buildSwipeableContent(context),
        ),
      ],
    );
  }

  Widget _buildTabHeader(
    BuildContext context,
    bool shouldShowAITab,
    bool shouldShowVirtualDict,
  ) {
    if (!shouldShowAITab) {
      return _buildNarrowHeader(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: context.appColorScheme.background.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(
                color: context.appColorScheme.border.dividerColor,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildTab(
                  context,
                  DictionaryTabType.dictionary,
                  'Dictionary',
                ),
              ),
              Expanded(child: _buildTab(context, DictionaryTabType.ai, 'AI')),
            ],
          ),
        ),
        if (shouldShowVirtualDict && _currentTab == DictionaryTabType.ai)
          _buildAISubTabs(context),
      ],
    );
  }

  Widget _buildAISubTabs(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.appColorScheme.background.surface.withValues(alpha: 0.5),
      ),
      child: Row(
        children: [
          _buildAITab(context, AITabType.translation, 'Translation'),
          const SizedBox(width: 16),
          _buildAITab(context, AITabType.virtualDictionary, 'Explanation'),
        ],
      ),
    );
  }

  Widget _buildAITab(BuildContext context, AITabType tab, String label) {
    final isSelected = _currentAITab == tab;

    return GestureDetector(
      onTap: () {
        setState(() {
          _currentAITab = tab;
          if (tab == AITabType.translation && !_hasFetchedAI) {
            _fetchAITranslation();
          } else if (tab == AITabType.virtualDictionary &&
              !_hasFetchedVirtualDict) {
            _fetchVirtualDictionary();
          }
        });
      },
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          color: isSelected
              ? context.m3Primary
              : context.appColorScheme.text.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildTab(BuildContext context, DictionaryTabType tab, String label) {
    final isSelected = _currentTab == tab;

    return GestureDetector(
      onTap: () {
        setState(() {
          _currentTab = tab;
        });
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? context.m3Primary
                  : context.m3Primary.withValues(alpha: 0.0),
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: isSelected
                ? context.m3Primary
                : context.appColorScheme.text.primary.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(BuildContext context, bool shouldShowVirtualDict) {
    switch (_currentTab) {
      case DictionaryTabType.dictionary:
        if (widget.dictionaries.isEmpty) {
          return _buildNoDictionariesState(context);
        }
        return Column(
          children: [
            _buildNarrowHeader(context),
            const SizedBox(height: 8),
            Expanded(child: _buildSwipeableContent(context)),
          ],
        );
      case DictionaryTabType.ai:
        return _buildAIContent(context, shouldShowVirtualDict);
    }
  }

  Widget _buildAIContent(BuildContext context, bool shouldShowVirtualDict) {
    if (_currentAITab == AITabType.virtualDictionary) {
      return _buildVirtualDictionaryContent(context);
    }
    return _buildAITranslationContent(context);
  }

  Widget _buildVirtualDictionaryContent(BuildContext context) {
    if (_isLoadingVirtualDict) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_virtualDictionaryError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: context.error),
              const SizedBox(height: 16),
              Text(
                'Virtual Dictionary Failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _virtualDictionaryError!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetchVirtualDictionary,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_virtualDictionaryContent != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories, color: context.m3Primary),
                const SizedBox(width: 8),
                Text(
                  'AI Explanation',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.appColorScheme.background.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.m3Primary.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Term: ',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        widget.term,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _virtualDictionaryContent!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _fetchVirtualDictionary,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildAITranslationContent(BuildContext context) {
    if (_isLoadingAI) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_aiErrorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: context.error),
              const SizedBox(height: 16),
              Text(
                'AI Translation Failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _aiErrorMessage!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetchAITranslation,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_aiTranslation != null) {
      final translations = _splitTranslations(_aiTranslation!);

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Term: ${widget.term}',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              'AI Translation:',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: context.m3Primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...translations.map((translation) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.appColorScheme.text.primary.withValues(
                      alpha: 0.08,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: context.m3Primary.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          translation,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontStyle: FontStyle.italic),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => _handleAddToTranslation(translation),
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        tooltip: 'Add translation',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _fetchMoreAITranslations,
              icon: const Icon(Icons.add),
              label: const Text('More'),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildNoDictionariesState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book,
              size: 48,
              color: context.appColorScheme.text.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'No dictionaries configured',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.appColorScheme.text.primary.withValues(
                  alpha: 0.6,
                ),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return InAppWebView(
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
    );
  }

  Widget _buildNarrowHeader(BuildContext context) {
    if (widget.dictionaries.isEmpty) return const SizedBox.shrink();

    final currentDict = widget.dictionaries[_currentPage];
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.appColorScheme.background.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: context.appColorScheme.border.dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: _currentPage > 0
                ? () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                    );
                  }
                : null,
          ),
          Expanded(
            child: Text(
              currentDict.name,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: _currentPage < widget.dictionaries.length - 1
                ? () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                    );
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSwipeableContent(BuildContext context) {
    if (widget.dictionaries.isEmpty) return const SizedBox.shrink();

    return PageView.builder(
      controller: _pageController,
      allowImplicitScrolling: true,
      onPageChanged: (index) async {
        if (_isPreloading) return;
        setState(() {
          _currentPage = index;
        });
        await widget.dictionaryService.rememberLastUsedDictionary(
          widget.languageId,
          widget.dictionaries[index].name,
        );
      },
      itemCount: widget.dictionaries.length,
      itemBuilder: (context, index) {
        return _buildWebViewPage(context, widget.dictionaries[index], index);
      },
    );
  }

  Widget _buildWebViewPage(
    BuildContext context,
    DictionarySource dictionary,
    int index,
  ) {
    // 本地词典：设置页下载进本机池的那一本直接查本机 sqlite，断网也能看。
    // 只有"本机没有这本词典"（还没下载 / 文件坏了）时才回落服务器渲染的
    // HTML——那时和在 Web 端看词典是一样的。
    if (dictionary.isLocalDictionary) {
      if (!_localLookupsDone) {
        return const Center(child: CircularProgressIndicator());
      }
      final local = _localLookups[index];
      if (local != null && local.available) {
        return _buildLocalGlossPage(context, local.gloss);
      }
    }

    // 本地词典的模板是服务器池里的 .db 文件名，必须换成服务端的查询路由；
    // 直接把它塞给 WebUri 会变成 http://<文件名>/（ERR_NAME_NOT_RESOLVED）。
    final serverUrl = ref.read(apiServiceProvider).baseUrl;
    final url = widget.dictionaryService.buildDictionaryUrl(
      term: widget.term,
      dictionary: dictionary,
      languageId: widget.languageId,
      serverUrl: serverUrl,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          height: constraints.maxHeight,
          child: _RemoteDictWebView(
            url: url,
            // 凭证只发给自己的服务器：在线词典（jisho / weblio / 有道…）
            // 是第三方站点，绝不能带上 Basic Auth 与会话 cookie。
            headers: dictionary.isLocalDictionary
                ? SessionManager.authHeaders()
                : null,
            settings: DictionaryService.webviewSettings(
              localDictionary: dictionary.isLocalDictionary,
            ),
            onCreated: (controller) {
              _webviewControllers[dictionary.hashCode] = controller;
              // 上面的 header 只作用于首个请求：本地词典页里的交叉引用
              // （← /read/localdict/... 链接）是 WebView 自己发起的后续
              // 导航，带不上自定义 header，多用户模式下会被 302 到 /login。
              // 把会话 cookie 写进 WebView 的 cookie store 才能一路可用。
              if (dictionary.isLocalDictionary) {
                unawaited(DictionaryService.installSessionCookie(serverUrl));
              }
            },
            onLoadStop: (controller, url) {
              if (index == _currentPage) {
                _preloadAdjacentPages();
              }
              if (url != null && url.path.contains('/login')) {
                _reportLoginRequired();
              }
            },
          ),
        );
      },
    );
  }

  /// 本机词典释义：纯文本按行渲染（`.db` 里的释义本来就是剥过 HTML 的）。
  Widget _buildLocalGlossPage(BuildContext context, String? gloss) {
    final text = gloss?.trim() ?? '';
    if (text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Not in the installed dictionary.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.appColorScheme.text.primary.withValues(
                alpha: 0.6,
              ),
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(height: 1.55),
      ),
    );
  }

  /// 本地词典页被登录门禁重定向时给一次提示，而不是让用户盯着登录页。
  void _reportLoginRequired() {
    if (_loginNoticeShown || !mounted) return;
    _loginNoticeShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Server login required for local dictionaries. '
            'Log in under Settings > Server.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    });
  }
}

/// 需要联网的词典页（在线词典，以及本机没下载的本地词典）。
///
/// 加载失败时必须自己说明白：WebView 默认给的是"黑屏"（还没画出内容就断了）
/// 或者满屏 Cloudflare / 浏览器的英文错误页，用户看到的就是"词典是个黑框"。
/// 这里垫一层自己的底色，并在主文档出错时盖一张可读的失败提示 + 重试。
class _RemoteDictWebView extends StatefulWidget {
  const _RemoteDictWebView({
    required this.url,
    required this.headers,
    required this.settings,
    this.onCreated,
    this.onLoadStop,
  });

  final String url;
  final Map<String, String>? headers;
  final InAppWebViewSettings settings;
  final void Function(InAppWebViewController)? onCreated;
  final void Function(InAppWebViewController, WebUri?)? onLoadStop;

  @override
  State<_RemoteDictWebView> createState() => _RemoteDictWebViewState();
}

class _RemoteDictWebViewState extends State<_RemoteDictWebView> {
  InAppWebViewController? _controller;
  String? _error;

  void _fail(String message) {
    if (!mounted || _error == message) return;
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 底色：WebView 还没画出第一帧、或者加载被打断时，露出来的是这个
        // 而不是平台视图的黑。
        Positioned.fill(
          child: ColoredBox(color: context.appColorScheme.background.surface),
        ),
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(widget.url),
            headers: widget.headers,
          ),
          initialSettings: widget.settings,
          // Deliberately *not* eager: this WebView lives inside the tab
          // PageView, and an eager recognizer would swallow the horizontal
          // drag that switches dictionaries.  A vertical drag recognizer
          // takes the arena team after touch slop (~18 px, invisible), which
          // is enough to stop the platform view from buffering the whole
          // gesture until the finger lifts; a horizontal drag still reaches
          // the PageView.
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory(() => VerticalDragGestureRecognizer()),
          },
          onWebViewCreated: (controller) {
            _controller = controller;
            widget.onCreated?.call(controller);
          },
          onLoadStop: (controller, url) {
            if (_error != null) setState(() => _error = null);
            widget.onLoadStop?.call(controller, url);
          },
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame != true) return;
            // CANCELLED 是自己发起的跳转/重新加载打断的，不是失败。
            if (error.type == WebResourceErrorType.CANCELLED) return;
            _fail(error.description);
          },
          onReceivedHttpError: (controller, request, response) {
            if (request.isForMainFrame != true) return;
            final status = response.statusCode ?? 0;
            if (status < 400) return;
            _fail('HTTP $status');
          },
        ),
        if (_error != null) Positioned.fill(child: _buildError(context)),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    final colors = context.appColorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ColoredBox(
      color: colors.background.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 40,
                color: colors.text.primary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Dictionary could not be loaded',
                textAlign: TextAlign.center,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.text.primary.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() => _error = null);
                  _controller?.reload();
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
