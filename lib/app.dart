import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/core/logger/api_logger.dart';
import 'package:song_mobile/features/reader/widgets/reader_screen.dart';
import 'package:song_mobile/features/reader/widgets/reader_drawer_settings.dart';
import 'package:song_mobile/features/reader/widgets/sentence_reader_screen.dart';
import 'package:song_mobile/features/reader/providers/audio_player_provider.dart';
import 'package:song_mobile/features/reader/providers/current_book_provider.dart';

import 'package:song_mobile/features/settings/widgets/settings_screen.dart';
import 'package:song_mobile/features/settings/widgets/help_screen.dart';
import 'package:song_mobile/features/books/widgets/books_screen.dart';
import 'package:song_mobile/features/books/widgets/books_drawer_settings.dart';
import 'package:song_mobile/features/terms/widgets/terms_screen.dart';
import 'package:song_mobile/features/stats/widgets/stats_screen.dart';
import 'package:song_mobile/features/grammar/widgets/grammar_screen.dart';
import 'package:song_mobile/shared/theme/app_theme.dart';
import 'package:song_mobile/shared/theme/eink.dart';
import 'package:song_mobile/shared/theme/theme_definitions.dart';
import 'package:song_mobile/shared/theme/theme_extensions.dart';
import 'package:song_mobile/features/settings/providers/settings_provider.dart';
import 'package:song_mobile/features/settings/models/settings.dart';
import 'package:song_mobile/shared/widgets/app_drawer.dart';
import 'package:song_mobile/features/books/providers/books_provider.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/core/services/termux_service.dart';
import 'package:song_mobile/shared/providers/app_startup_providers.dart';
import 'package:song_mobile/shared/providers/network_providers.dart';

class RestartWidget extends StatefulWidget {
  final Widget child;

  const RestartWidget({super.key, required this.child});

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<_RestartWidgetState>()?.restartApp();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key _key = UniqueKey();

  void restartApp() {
    setState(() {
      _key = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

final navigationProvider = Provider<NavigationController>((ref) {
  return NavigationController();
});

class CurrentScreenRouteNotifier extends Notifier<String> {
  @override
  String build() {
    return 'reader';
  }

  void setRoute(String route) {
    state = route;
  }
}

final currentScreenRouteProvider =
    NotifierProvider<CurrentScreenRouteNotifier, String>(() {
      return CurrentScreenRouteNotifier();
    });

/// 进入 Help / Settings 之前所在的主页面。
///
/// 这两屏是 IndexedStack 切页（不是 push 路由），底栏整体隐藏，返回按钮和
/// 系统返回键靠它决定回到哪里。必须是响应式 provider：SettingsScreen 在
/// IndexedStack 里 App 启动时就已构建，普通字段被按钮闭包缓存后不会更新，
/// 从 Books 进 Settings 再返回会错误地回到启动时的 Reader。
class LastMainRouteNotifier extends Notifier<String> {
  @override
  String build() => 'reader';

  void setRoute(String route) {
    state = route;
  }
}

final lastMainRouteProvider = NotifierProvider<LastMainRouteNotifier, String>(
  () {
    return LastMainRouteNotifier();
  },
);

class NavigationController {
  NavigationController._internal();
  static final NavigationController _instance =
      NavigationController._internal();
  factory NavigationController() => _instance;

  final List<Function(int, int?, Book?)> _readerListeners = [];
  final List<Function(String)> _screenListeners = [];

  void addReaderListener(Function(int, int?, Book?) listener) {
    if (!_readerListeners.contains(listener)) {
      _readerListeners.add(listener);
    }
  }

  void removeReaderListener(Function(int, int?, Book?) listener) {
    _readerListeners.remove(listener);
  }

  void addScreenListener(Function(String) listener) {
    if (!_screenListeners.contains(listener)) {
      _screenListeners.add(listener);
    }
  }

  void removeScreenListener(Function(String) listener) {
    _screenListeners.remove(listener);
  }

  /// 打开一本书。
  ///
  /// [book] 用于「书不在书架列表里」的场景 —— 目前只有 Book Set 的成员书：
  /// 它们被服务端聚合行隐藏，客户端拿不到对应的 [Book] 对象，
  /// 不传就会退化成一本没有标题、没有语言的空壳书。
  void navigateToReader(int bookId, [int? pageNum, Book? book]) {
    ApiLogger.logRequest(
      'NavigationController.navigateToReader',
      details: 'bookId=$bookId, pageNum=$pageNum, explicitBook=${book != null}',
    );
    for (final listener in List<Function(int, int?, Book?)>.from(
      _readerListeners,
    )) {
      try {
        listener(bookId, pageNum, book);
      } catch (e, stackTrace) {
        ApiLogger.logError(
          'navigateToReader.listener',
          e,
          stackTrace: stackTrace,
        );
      }
    }
    navigateToScreen('reader');
  }

  void navigateToScreen(String route) {
    for (final listener in List<Function(String)>.from(_screenListeners)) {
      try {
        listener(route);
      } catch (e, stackTrace) {
        ApiLogger.logError(
          'NavigationController.navigateToScreen.listener',
          e,
          stackTrace: stackTrace,
        );
      }
    }
  }
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(themeSettingsProvider);
    final eInk = ref.watch(einkModeProvider);

    ThemeMode themeMode;
    switch (themeSettings.themeType) {
      case ThemeType.light:
        themeMode = ThemeMode.light;
        break;
      case ThemeType.dark:
        themeMode = ThemeMode.dark;
        break;
      case ThemeType.blackAndWhite:
        themeMode = ThemeMode.light;
        break;
    }

    final lightTheme = switch (themeSettings.themeType) {
      ThemeType.blackAndWhite => AppTheme.blackAndWhiteTheme(themeSettings),
      _ => AppTheme.lightTheme(themeSettings),
    };
    final darkTheme = AppTheme.darkTheme(themeSettings);

    return EInkScope(
      enabled: eInk,
      child: RestartWidget(
        child: MaterialApp(
          title: 'LuteForMobile',
          debugShowCheckedModeBanner: false,
          theme: eInk ? applyEInkTheme(lightTheme) : lightTheme,
          darkTheme: eInk ? applyEInkTheme(darkTheme) : darkTheme,
          themeMode: themeMode,
          home: const MainNavigation(),
        ),
      ),
    );
  }
}

class MainNavigation extends ConsumerStatefulWidget {
  const MainNavigation({super.key});

  @override
  ConsumerState<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends ConsumerState<MainNavigation> {
  /// 唯一的导航状态：底栏高亮、IndexedStack 下标、抽屉设置都由它派生。
  String _currentRoute = 'reader';

  /// 宽度阈值：达到后用常驻 rail 取代「抽屉 + 底栏」这套组合。
  static const double _wideLayoutMinWidth = 600;

  /// 再宽一点就把 rail 展开成图标 + 文字（M3 的 NavigationRail extended）。
  static const double _extendedRailMinWidth = 900;
  final GlobalKey<ReaderScreenState> _readerKey =
      GlobalKey<ReaderScreenState>();
  final GlobalKey<State<StatefulWidget>> _booksKey =
      GlobalKey<State<StatefulWidget>>();
  final GlobalKey<State<StatefulWidget>> _statsKey =
      GlobalKey<State<StatefulWidget>>();
  final GlobalKey<State<StatefulWidget>> _settingsKey =
      GlobalKey<State<StatefulWidget>>();
  final GlobalKey<SentenceReaderScreenState> _sentenceReaderKey =
      GlobalKey<SentenceReaderScreenState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final NavigationController _navigationController;
  final GlobalKey<State<StatefulWidget>> _termsKey =
      GlobalKey<State<StatefulWidget>>();
  final GlobalKey<State<StatefulWidget>> _helpKey =
      GlobalKey<State<StatefulWidget>>();
  final GlobalKey<State<StatefulWidget>> _grammarKey =
      GlobalKey<State<StatefulWidget>>();
  bool _needsDataRefresh = false;

  @override
  void initState() {
    super.initState();
    _navigationController = ref.read(navigationProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentScreenRouteProvider.notifier).setRoute('reader');
      _updateDrawerSettings();
      _checkAndStartLute3IfNeeded();
      _loadLastReadBook();
    });
    _navigationController.addReaderListener(_handleNavigateToReader);
    _navigationController.addScreenListener(_handleNavigateToScreen);
  }

  Future<void> _checkAndStartLute3IfNeeded() async {
    final settings = ref.read(settingsProvider);
    if (settings.serverUrl == Settings.termuxUrl) {
      for (int i = 0; i < 15; i++) {
        final isRunning = await TermuxService.isServerRunning(
          settings.serverUrl,
        );
        if (isRunning) {
          if (_needsDataRefresh) {
            _needsDataRefresh = false;
            ref.read(booksProvider.notifier).loadBooks(forceRefresh: true);
            _loadLastReadBook();
          }
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @override
  void dispose() {
    _navigationController.removeReaderListener(_handleNavigateToReader);
    _navigationController.removeScreenListener(_handleNavigateToScreen);
    super.dispose();
  }

  void _handleNavigateToReader(int bookId, [int? pageNum, Book? book]) {
    final booksState = ref.read(booksProvider);
    final allBooks = [...booksState.activeBooks, ...booksState.archivedBooks];

    // 优先用调用方显式传入的 Book（Book Set 的成员书不在书架列表里，
    // 因为它们被聚合行隐藏了），其次才去书架列表里找。
    // 聚合行本身没有真实 BkID，永远不能当作书打开，所以必须排除。
    Book? resolved = (book != null && !book.isSeries) ? book : null;
    if (resolved == null) {
      for (final b in allBooks) {
        if (b.id == bookId && !b.isSeries) {
          resolved = b;
          break;
        }
      }
    }

    if (resolved != null) {
      ref
          .read(settingsProvider.notifier)
          .updateCurrentBook(bookId, pageNum, resolved.langId);
      ref.read(currentBookProvider.notifier).setBook(resolved);
    } else {
      // 兜底：拿不到可信的 Book 时只更新「当前书 id」，不写语言。
      // 旧代码在这里伪造了一本 langId=0 的空壳书，会把 currentBookLangId
      // 覆盖成 0，进而让 Stats / Terms 页的语言筛选失效。
      ref.read(settingsProvider.notifier).updateCurrentBook(bookId, pageNum);
    }

    ref.read(booksProvider.notifier).setCurrentBook(bookId);

    // The reader is a bottom-bar destination now, so the highlight comes from
    // the route rather than from a screen index.  navigateToScreen('reader')
    // runs right after this listener, but keeping the route honest here means
    // the drawer settings are rebuilt for the reader either way.
    if (_currentRoute != 'reader') {
      setState(() {
        _currentRoute = 'reader';
      });
      ref.read(currentScreenRouteProvider.notifier).setRoute('reader');
    }

    if (_readerKey.currentState != null) {
      _readerKey.currentState!.loadBook(bookId, pageNum);
    } else {
      ApiLogger.logError(
        '_handleNavigateToReader',
        Exception('Reader not ready'),
      );
    }
    _updateDrawerSettings();
  }

  void _handleNavigateToScreen(String route) {
    // 只有真正的内容页才更新"返回目标"；在 Help/Settings 之间来回切换时
    // 保留最初进入前的页面。
    if (route != 'help' && route != 'settings') {
      ref.read(lastMainRouteProvider.notifier).setRoute(route);
    }

    if (_currentRoute == 'reader' && route != 'reader') {
      ref.read(audioPlayerProvider.notifier).reset();
    }

    setState(() {
      _currentRoute = route;
    });

    if (route == 'books') {
      ref.read(booksProvider.notifier).loadBooks();
    }

    ref.read(currentScreenRouteProvider.notifier).setRoute(route);
    _updateDrawerSettings();
  }

  // ---------------------------------------------------------------------------
  // 底部导航
  // ---------------------------------------------------------------------------

  /// 底部导航的 5 个目的地对应的路由。
  ///
  /// Settings 与 Help 不在其中：侧边栏（抽屉）里已经有它们的入口，
  /// 底栏再放一个只是重复占位。空出来的中间位置给 Grammar。
  static const List<String> _navBarRoutes = <String>[
    'reader',
    'books',
    'grammar',
    'terms',
    'stats',
  ];

  /// Routes the drawer offers: only what the bar cannot.
  ///
  /// Where the bar is on screen it already carries the five main sections, so
  /// the drawer offers Help / Settings.  Repeating the bar's own destinations
  /// gave two copies of every entry point and cost the panel a quarter of its
  /// width.  Where the bar is hidden there is no other way to move, so the
  /// drawer offers everything.
  List<String> get _drawerRoutes {
    if (_navBarIndex == null) {
      return kNavDestinations.map((d) => d.route).toList(growable: false);
    }
    return const <String>['help', 'settings'];
  }

  /// Selected destination for the wide-screen rail; null when the current
  /// route is not one of them.
  int? get _railIndex {
    final route = _currentRoute == 'sentence-reader' ? 'reader' : _currentRoute;
    final index = kNavDestinations.indexWhere((d) => d.route == route);
    return index == -1 ? null : index;
  }

  /// 当前路由映射到底部导航的高亮项；null 表示底栏在这一屏不该出现。
  ///
  /// sentence-reader 与 reader 同属"阅读"分组，所以沿用 reader 的高亮。
  /// Help / Settings 只有侧边栏入口，此时整条底栏隐藏 —— NavigationBar 没有
  /// "无选中项"这个状态，与其把高亮错误地停在 Reader 上，不如不显示。
  int? get _navBarIndex {
    final index = _navBarRoutes.indexOf(_currentRoute);
    if (index >= 0) return index;
    if (_currentRoute == 'sentence-reader') return 0;
    return null;
  }

  /// IndexedStack 里各内容屏的下标。help / sentence-reader 是整屏页面，
  /// 不在这个栈里，单独渲染。
  static const Map<String, int> _stackRoutes = <String, int>{
    'reader': 0,
    'books': 1,
    'grammar': 2,
    'terms': 3,
    'stats': 4,
    'settings': 5,
  };

  void _handleNavBarTap(int index) {
    _handleNavTap(_navBarRoutes[index]);
  }

  void _handleNavTap(String route) {
    HapticFeedback.selectionClick();
    _handleNavigateToScreen(route);
    if (route == 'reader' && _readerKey.currentState != null) {
      _readerKey.currentState!.reloadPage();
    }
  }

  void _loadLastReadBook() async {
    final settings = ref.read(settingsProvider);
    if (settings.currentBookId == null) return;

    if (_readerKey.currentState != null) {
      await _readerKey.currentState!.loadBook(settings.currentBookId!);
    }
  }

  void _updateDrawerSettings() {
    final currentRoute = ref.read(currentScreenRouteProvider);
    switch (currentRoute) {
      case 'reader':
      case 'sentence-reader':
        ref
            .read(currentViewDrawerSettingsProvider.notifier)
            .updateSettings(ReaderDrawerSettings(currentRoute: currentRoute));
        break;
      case 'books':
        ref
            .read(currentViewDrawerSettingsProvider.notifier)
            .updateSettings(const BooksDrawerSettings());
        break;
      case 'settings':
      case 'terms':
      case 'stats':
      case 'grammar':
      case 'help':
        // Settings 整页里再塞一块"阅读快捷设置"面板既错位又和页面本身
        // 重复 —— 此时抽屉应退化成纯导航菜单（含全部 7 个入口）。
        ref
            .read(currentViewDrawerSettingsProvider.notifier)
            .updateSettings(null);
        break;
      default:
        ref
            .read(currentViewDrawerSettingsProvider.notifier)
            .updateSettings(null);
    }
  }

  bool _autoBackupTriggered = false;

  void _triggerAutoBackup() {
    final settings = ref.read(settingsProvider);
    if (settings.serverUrl.isNotEmpty && !_autoBackupTriggered) {
      _autoBackupTriggered = true;
      ref.read(apiServiceProvider).triggerAutoBackup();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Trigger auto backup if books already loaded, otherwise listen for it
    final booksLoaded = ref.read(booksLoadingCompleteProvider);
    if (booksLoaded) {
      _triggerAutoBackup();
    }

    // Listen for books loading completion and trigger auto backup
    ref.listen(booksLoadingCompleteProvider, (previous, next) {
      if (next == true && previous != true) {
        _triggerAutoBackup();
      }
    });

    // Also listen for settings to load and trigger backup
    ref.listen(settingsProvider, (previous, next) {
      if (previous?.serverUrl.isEmpty == true && next.serverUrl.isNotEmpty) {
        _triggerAutoBackup();
      }
    });

    // 宽屏（平板 / 横屏）：左侧常驻 NavigationRail，抽屉与底栏都收起 ——
    // 两者并存时必然重复，而宽屏有位置把导航常驻出来。
    final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutMinWidth;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isWide
          ? null
          : AppDrawer(
              currentRoute: ref.watch(currentScreenRouteProvider),
              onNavigate: _handleNavTap,
              routes: _drawerRoutes,
            ),
      // 底部导航：Reader | Books | Grammar | Terms | Stats。
      // 抽屉与各屏幕原有的汉堡按钮全部保留，Help / Settings 也只在抽屉里，
      // 所以这一屏即使表现不如预期，原有的操作路径依然可用。
      bottomNavigationBar: isWide || _navBarIndex == null
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: context.appColorScheme.border.dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: NavigationBar(
                selectedIndex: _navBarIndex!,
                onDestinationSelected: _handleNavBarTap,
                // 显式指定背景：项目的 ColorScheme 未声明 surfaceContainer，
                // 不指定的话 NavigationBar 会回退到 M3 baseline 的浅紫。
                // 指示器沿用默认的 secondaryContainer —— 三个主题都已声明该色，
                // 且与各自 surface 有足够差异（浅 #FFFBFE/#E8DEF8、深 #1E1E1E/#4A4458、
                // 黑白 #FFFFFF/#EEEEEE），不会出现指示器与背景撞色。
                backgroundColor: context.appColorScheme.background.surface,
                elevation: 0,
                destinations: const <NavigationDestination>[
                  NavigationDestination(
                    icon: Icon(Icons.book),
                    label: 'Reader',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.collections_bookmark),
                    label: 'Books',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.spellcheck),
                    label: 'Grammar',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.translate),
                    label: 'Terms',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.bar_chart),
                    label: 'Stats',
                  ),
                ],
              ),
            ),
      body: _buildBody(isWide),
    );
  }

  /// The current screen, plus the rail on wide layouts.
  Widget _buildBody(bool isWide) {
    final content = _currentRoute == 'help'
        ? HelpScreen(key: _helpKey, scaffoldKey: _scaffoldKey)
        : _currentRoute == 'sentence-reader'
        ? SentenceReaderScreen(
            key: _sentenceReaderKey,
            scaffoldKey: _scaffoldKey,
          )
        : IndexedStack(
            index: _stackRoutes[_currentRoute] ?? 0,
            children: [
              Consumer(
                builder: (context, ref, child) =>
                    ReaderScreen(key: _readerKey, scaffoldKey: _scaffoldKey),
              ),
              Consumer(
                builder: (context, ref, child) =>
                    BooksScreen(key: _booksKey, scaffoldKey: _scaffoldKey),
              ),
              Consumer(
                builder: (context, ref, child) =>
                    GrammarScreen(key: _grammarKey, scaffoldKey: _scaffoldKey),
              ),
              Consumer(
                builder: (context, ref, child) =>
                    TermsScreen(key: _termsKey, scaffoldKey: _scaffoldKey),
              ),
              Consumer(
                builder: (context, ref, child) =>
                    StatsScreen(key: _statsKey, scaffoldKey: _scaffoldKey),
              ),
              Consumer(
                builder: (context, ref, child) => SettingsScreen(
                  key: _settingsKey,
                  scaffoldKey: _scaffoldKey,
                ),
              ),
            ],
          );

    if (!isWide) return content;

    return Row(
      children: [
        _buildRail(),
        const VerticalDivider(width: 1),
        Expanded(child: content),
      ],
    );
  }

  /// Wide-screen navigation: one permanent rail holding every destination,
  /// Help and Settings included.  Unlike the bottom bar it can express "on a
  /// screen that is not one of these" (selectedIndex null), so no screen has
  /// to hide it.
  Widget _buildRail() {
    final width = MediaQuery.sizeOf(context).width;
    return NavigationRail(
      extended: width >= _extendedRailMinWidth,
      selectedIndex: _railIndex,
      onDestinationSelected: (index) =>
          _handleNavTap(kNavDestinations[index].route),
      backgroundColor: context.appColorScheme.background.surface,
      destinations: <NavigationRailDestination>[
        for (final destination in kNavDestinations)
          NavigationRailDestination(
            icon: Icon(destination.icon),
            label: Text(destination.label),
          ),
      ],
    );
  }
}
