import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../core/logger/api_logger.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/widgets/outbox_status_indicator.dart';
import '../../../shared/theme/eink.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/hardware_key_navigator.dart';
import '../../../shared/utils/language_flag_mapper.dart';
import '../../../shared/utils/tts_speak_text.dart';
import '../../../features/settings/providers/settings_provider.dart';
import '../../../features/settings/providers/tts_settings_provider.dart';
import '../../../features/settings/models/tts_settings.dart';
import '../../../features/settings/models/settings.dart';
import '../../../features/terms/providers/terms_provider.dart';
import '../../books/providers/books_provider.dart';
import '../../../features/stats/providers/stats_provider.dart';
import '../../../features/stats/models/stats_data.dart';
import '../../../core/services/termux_service.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../../../core/cache/providers/book_progress_provider.dart';
import '../../../core/outbox/providers/outbox_provider.dart';
import '../models/text_item.dart';
import '../models/paragraph.dart';
import '../models/term_form.dart';
import '../models/page_data.dart';
import '../models/term_tooltip.dart';
import '../providers/reader_provider.dart';
import '../providers/audio_player_provider.dart';
import '../providers/player_mode_provider.dart';
import '../providers/sentence_tts_provider.dart';
import '../providers/tts_player_provider.dart';
import '../providers/current_book_provider.dart';
import '../../grammar/providers/grammar_provider.dart';
import '../../grammar/providers/sentence_grammar_provider.dart';
import '../../grammar/widgets/sentence_grammar_screen.dart';
import '../utils/playing_line.dart';
import '../utils/player_lifecycle.dart';
import '../widgets/term_tooltip.dart';
import 'text_display.dart';
import 'term_form.dart';
import 'sentence_translation.dart';
import 'book_completion_celebration_dialog.dart';
import '../../../core/network/dictionary_service.dart';
import '../../../core/network/session_manager.dart';
import 'audio_player.dart';
import 'package:song_mobile/app.dart';
import 'manga_page_view.dart';
import 'pdf_page_view.dart';
import 'youtube_player_view.dart';
import 'tts_player_widget.dart';
import '../../shadowing/models/shadowing_sentence.dart';
import '../../shadowing/providers/shadowing_provider.dart';
import '../../shadowing/widgets/shadowing_sheet.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const ReaderScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<ReaderScreen> createState() => ReaderScreenState();
}

class _PageTransition extends StatefulWidget {
  final Widget child;
  final bool isForward;

  const _PageTransition({
    required this.child,
    required this.isForward,
    Key? key,
  }) : super(key: key);

  @override
  State<_PageTransition> createState() => _PageTransitionState();
}

class _PageTransitionState extends State<_PageTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Widget _oldChild;
  Widget? _currentChild;
  bool _hasAnimated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _currentChild = widget.child;
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(_PageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child.key != widget.child.key) {
      _oldChild = oldWidget.child;
      _currentChild = widget.child;
      _controller.forward(from: 0.0);
      _hasAnimated = true;
    } else if (oldWidget.child != widget.child) {
      _currentChild = widget.child;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (!_hasAnimated) {
          return _currentChild ?? const SizedBox();
        }

        return Stack(
          children: [
            if (_oldChild.key != _currentChild?.key)
              SlideTransition(
                position:
                    Tween<Offset>(
                      begin: Offset.zero,
                      end: widget.isForward
                          ? const Offset(-1.0, 0.0)
                          : const Offset(1.0, 0.0),
                    ).animate(
                      CurvedAnimation(
                        parent: _controller,
                        // 旧页滑出：翻页是用户甩动之后发生的，
                        // easeInOut 的「慢开头」会让人觉得迟钝，
                        // 换成 easeOutCubic 立即起步、平滑收尾。
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                child: _oldChild,
              ),
            SlideTransition(
              position:
                  Tween<Offset>(
                    begin: widget.isForward
                        ? const Offset(1.0, 0.0)
                        : const Offset(-1.0, 0.0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: _controller,
                      // 新页滑入：与旧页同一条曲线，保持两张页面同步。
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: _currentChild,
            ),
          ],
        );
      },
    );
  }
}

class ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  int _buildCount = 0;
  TermForm? _currentTermForm;
  bool _isUiVisible = true;
  bool _lastFullscreenMode = false;
  Timer? _hideUiTimer;
  Timer? _glowTimer;

  /// 翻页后延迟触发整页语法预分析的定时器（见 build 里的 pageData 监听）。
  Timer? _grammarPreAnalysisTimer;
  int? _highlightedWordId;
  int? _highlightedParagraphId;
  int? _highlightedOrder;
  TextItem? _originalTextItem;
  bool _isMultiTermSelecting = false;

  /// Manga 页文字框的「全部显示」开关，挂在顶栏的眼睛图标上（web 端
  /// 对应 mokuro 的 text-visible 模式）。框的单独点显/钉住由
  /// MangaPageView 自己管理。翻页不重置：缩放一样是跨页的阅读偏好。
  bool _mangaRevealAll = false;

  /// Manga 页的「适应全屏」开关，挂在顶栏的 fit 图标上（web 端对应
  /// lute.js 的 "Fit page to screen"）。关 = 适应宽度（整页纵向平移），
  /// 开 = 整页缩放进可视区、左右留白。翻页不重置，与缩放偏好同理。
  bool _mangaFitToScreen = false;

  /// Bumped on every word tap.  _handleTap has to await a fetch before it can
  /// show the card, and the second tap of a double tap can land inside that
  /// window: the stale response then re-opens the card on top of whatever the
  /// second tap produced.  Capturing the sequence at entry and comparing it
  /// after the await lets the late response bow out.  onTap fires immediately
  /// (text_display.dart:285), so this is the normal case, not a rare race.
  int _tooltipSeq = 0;

  /// Bumped on every long press that asks for a term form.  The form is built
  /// from a server round trip, and the long-press buzz lands long before the
  /// sheet does: pressing again inside that window queues one sheet per press,
  /// so three long presses end in three identical cards.  Same rule as
  /// _tooltipSeq above -- only the newest gesture gets to draw.
  int _termFormSeq = 0;

  /// 实体键的焦点节点。从别的屏（设置等）回到阅读屏时要把焦点收回来 ——
  /// IndexedStack 常驻其它屏，那里的输入框（如设置页的 Server Host）会
  /// 拿走焦点且不还，实体键从此失灵直到重启 app。
  final FocusNode _hardwareKeyFocus = FocusNode();

  /// Statuses a double tap cycles through, matching the web reader's
  /// _quick_cycle_status (lute-touch.js).  2/4/5 are skipped so the gesture
  /// stays a predictable three-way toggle.
  static const List<String> _statusCycle = ['1', '3', '99'];
  ScrollController _scrollController = ScrollController();
  double _lastScrollPosition = 0.0;
  bool _isLastPageMarkedDone = false;
  int? _lastAttemptedBookId;
  int? _lastAttemptedPageNum;

  /// 本次运行是否已经为「上次在读的书」拿到过结果（正文或错误）。
  ///
  /// 用来把「正在恢复」和「真的没开书」区分开：前者不该显示
  /// "No Book Loaded"，后者才该。
  bool _hasLoadedOnce = false;
  bool _isNavigatingForward = true;
  Key _pageKey = const ValueKey('page');
  Map<int, String> _languageIdToName = {};
  final Map<int, TextDirection> _languageIdToDirection = {};
  final Set<int> _languageDirectionLoadsInFlight = {};
  int? _lastStatsLangId;
  bool _checkServerPageInProgress = false;
  int? _lastAudioBookId;
  String? _lastTtsPageKey;

  /// Cue the online video player's playhead is on, or -1 when it is outside
  /// every cue.  Reported by [YoutubePlayerView]; the player outlives a page
  /// turn (it is keyed by book, not page), so this is deliberately not reset
  /// when the page changes -- a cue that is not on the new page simply marks
  /// nothing.
  int _activeCueIndex = -1;

  /// 最近一次 build 算出的"正在播放"的句子集合(TTS 朗读句或媒体播放句),
  /// 影子跟读面板打开时据此定位当前句。
  Set<int> _shadowingSentenceIds = const {};

  /// 有字母/数字才算"词":假名、汉字、拉丁字母都算,标点、空白不算。
  static final RegExp _wordCharPattern = RegExp(
    r'[\p{L}\p{N}]',
    unicode: true,
  );

  // --- 拖动跟手翻页 ---
  /// 最近一次按下的横坐标（屏幕坐标）。墨水屏模式下靠它判断点的是左半屏还是
  /// 右半屏 —— 那里没有拖动，翻页只认左右区域。
  double _lastTapX = 0.0;

  /// 水平拖动位移（像素）。正数 = 往右拖（看上一页），负数 = 往左拖（下一页）。
  double _dragOffset = 0.0;

  /// 是否正在水平拖动中。用于在「跟手（0ms）」与「回弹（200ms）」之间切换过渡时长。
  bool _isDragActive = false;

  /// 当前是否允许左右滑动翻页。
  /// 与滑动翻页原有的前置判断保持一致，避免在漫画页、多选模式、
  /// 或关闭了滑动翻页时仍然跟着手指移动。
  bool _canSwipePages(PageData? pageData) {
    if (_isMultiTermSelecting) return false;
    if (pageData == null || pageData.pageCount <= 1) return false;
    // 墨水屏下翻页只剩点击区域与物理键两条路，都不经过拖动手势，
    // 不该被「swipe navigation」这个触屏开关连坐（Leaf 5C 实测该开关
    // 默认关，会把两种翻页全部掐死）。
    if (context.eInk) return true;
    // 漫画页的翻页手势（点按分区、横滑）画在 MangaPageView 内部，是漫画
    // 阅读本身的一部分，也不受 swipeNavigation 开关连坐。PDF 页同理
    // （手势在 PdfPageView 内部）。
    if (pageData.isManga || pageData.isPdf) return true;
    if (!ref.read(textFormattingSettingsProvider).swipeNavigationEnabled) {
      return false;
    }
    return true;
  }

  /// 实体键（BOOX 翻页键/音量键）分发：
  ///  * TTS 播放条在显示且循环/自动暂停激活 → 上下键切句；
  ///  * MP3 播放条在显示且循环/自动暂停激活 → 上下键切 SRT 句子
  ///    （segmentBoundaries，与主排左右键同一数据源）；
  ///  * 首/末顶住或未开循环/自动暂停 → 翻页，阅读流不中断。
  ///
  /// TTS 的门控用 [_showTtsPlayer]（「TTS 条是不是当前显示的播放条」）而不是
  /// playerMode：纯文本书没有音频，TTS 条常显，但 playerMode 仍停在进书
  /// 默认的 mp3 —— 按 playerMode 判断会在这种书上永远走翻页分支。
  void _handleHardwareKey(HardwareKeyAction action, PageData? pageData) {
    if (pageData != null) {
      final settings = ref.read(settingsProvider);
      if (_showTtsPlayer(pageData, settings)) {
        final tts = ref.read(ttsPlayerProvider);
        if (tts.loopMode || tts.autoPauseMode) {
          final canMove = action == HardwareKeyAction.previous
              ? tts.canGoPrevious
              : tts.canGoNext;
          if (canMove) {
            HapticFeedback.selectionClick();
            action == HardwareKeyAction.previous
                ? ref.read(ttsPlayerProvider.notifier).previous()
                : ref.read(ttsPlayerProvider.notifier).next();
            return;
          }
        }
      } else if (settings.showAudioPlayer &&
          pageData.hasAudio &&
          ref.read(playerModeProvider) == PlayerMode.mp3) {
        final audio = ref.read(audioPlayerProvider);
        if (audio.loopMode || audio.autoPauseMode) {
          // 与 goToPrevious/NextSegment 的"相邻句"判定同源：自动暂停停在
          // 句首时，上一句要求 800ms 之外还有更早的边界。顶住了就回落为翻页。
          final canMove = action == HardwareKeyAction.previous
              ? audio.segmentBoundaries.any(
                  (b) =>
                      audio.position - b > const Duration(milliseconds: 800),
                )
              : audio.segmentBoundaries.any((b) => b > audio.position);
          if (canMove) {
            HapticFeedback.selectionClick();
            action == HardwareKeyAction.previous
                ? ref.read(audioPlayerProvider.notifier).goToPreviousSegment()
                : ref.read(audioPlayerProvider.notifier).goToNextSegment();
            return;
          }
        }
      }
    }
    _turnPage(action == HardwareKeyAction.previous ? 1 : -1, pageData);
  }

  /// 按方向翻页：direction > 0 上一页，< 0 下一页。
  ///
  /// 拖动翻页与墨水屏的左右区域点击共用这一条路径 —— 墨水屏下没有拖动，
  /// 只有点击（跟手位移每帧都要刷一次屏，见 onHorizontalDragStart）。
  void _turnPage(int direction, PageData? pageData) {
    if (direction == 0 || pageData == null) return;
    if (!_canSwipePages(pageData)) return;
    final textSettings = ref.read(textFormattingSettingsProvider);
    if (direction > 0) {
      if (pageData.currentPage > 1) {
        HapticFeedback.lightImpact();
        _loadPageWithoutMarkingRead(pageData.currentPage - 1);
      }
    } else {
      if (pageData.currentPage < pageData.pageCount) {
        HapticFeedback.lightImpact();
        if (textSettings.swipeMarksRead) {
          // Now a local outbox record rather than a POST, so leaving it
          // un-awaited is finally safe -- this used to be an unhandled async
          // error with no signal, and the read stat was simply lost.
          unawaited(
            ref
                .read(readerProvider.notifier)
                .markPageRead(pageData.bookId, pageData.currentPage),
          );
        }
        _loadPageWithoutMarkingRead(pageData.currentPage + 1);
      }
    }
  }

  Future<void> _loadLanguageMapping() async {
    if (_languageIdToName.isNotEmpty) return;

    final repository = ref.read(readerRepositoryProvider);
    try {
      final languages = await repository.contentService.getLanguagesWithIds();
      setState(() {
        _languageIdToName = {for (var lang in languages) lang.id: lang.name};
      });
    } catch (e) {
      ApiLogger.logError('loadLanguageMapping', e);
    }
  }

  int? _findLangId(PageData? pageData) {
    if (pageData == null) return null;

    for (final paragraph in pageData.paragraphs) {
      for (final item in paragraph.textItems) {
        final langId = item.langId;
        if (langId != null && langId != 0) {
          return langId;
        }
      }
    }

    // Manga 页的 HTML 没有 .textsentence 包裹，paragraphs 恒为空 —— 只扫
    // paragraphs 的话这里拿到 null，TTS 语言退回兜底 'en'，日文词被丢给
    // 英文语音（edge-tts 422，词卡彻底无声，见 nginx 日志 /tts/en/言う）。
    // OCR 文字项带同样的 data-lang-id，从 manga blocks 里补扫一遍。
    final mangaPage = pageData.mangaPage;
    if (mangaPage != null) {
      for (final block in mangaPage.blocks) {
        for (final line in block.lineItems) {
          for (final item in line) {
            final langId = item.langId;
            if (langId != null && langId != 0) {
              return langId;
            }
          }
        }
      }
    }

    // PDF 页同理：paragraphs 恒为空，词项挂在 pdfPage.words 上。
    final pdfPage = pageData.pdfPage;
    if (pdfPage != null) {
      for (final word in pdfPage.words) {
        for (final item in word.items) {
          final langId = item.langId;
          if (langId != null && langId != 0) {
            return langId;
          }
        }
      }
    }

    return null;
  }

  Future<void> _ensureLanguageDirectionLoaded(int langId) async {
    if (_languageIdToDirection.containsKey(langId) ||
        _languageDirectionLoadsInFlight.contains(langId)) {
      return;
    }

    _languageDirectionLoadsInFlight.add(langId);

    final repository = ref.read(readerRepositoryProvider);
    try {
      final settings = await repository.contentService.getLanguageCardSettings(
        langId,
      );
      if (!mounted) return;

      setState(() {
        _languageIdToDirection[langId] = settings.rightToLeft
            ? TextDirection.rtl
            : TextDirection.ltr;
      });
    } catch (e) {
      ApiLogger.logError('ensureLanguageDirectionLoaded', e);
    } finally {
      _languageDirectionLoadsInFlight.remove(langId);
    }
  }

  void _loadStatsIfNeeded() {
    final statsState = ref.read(statsProvider);
    if (statsState.value == null && !statsState.isLoading) {
      ref.read(statsProvider.notifier).loadStats();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScrollPosition);

    Future.delayed(Duration.zero, _loadLanguageMapping);
    Future.delayed(Duration.zero, _loadStatsIfNeeded);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideUiTimer?.cancel();
    _glowTimer?.cancel();
    _grammarPreAnalysisTimer?.cancel();
    _scrollController.removeListener(_handleScrollPosition);
    _scrollController.dispose();
    _hardwareKeyFocus.dispose();
    ref.read(audioPlayerProvider.notifier).reset();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      _checkAndStartLute3IfNeeded();
      if (!_checkServerPageInProgress) {
        _checkServerPage();
      }
      // 回到前台把播放条复位到切走前的位置。`_checkServerPage()` 只在服务端
      // 页码不同时才翻页，所以这条路径不会重新装载音频，位置得自己还回来。
      ref.read(audioPlayerProvider.notifier).restoreAfterBackground();
    } else if (shouldStopAudioOnLifecycleChange(state)) {
      // 只在真正切后台时停 MP3。inactive（窗口失焦）不算离开 app ——
      // 音量面板、控制中心、权限弹窗都会触发它，理由见
      // utils/player_lifecycle.dart。
      //
      // 用 suspendForBackground 而不是 reset：切后台只是停播，回来还在同一
      // 本书、同一页、同一位置，不该连音源和进度一起卸掉 —— 那样播放条会
      // 归零，而且按播放也起不来（重装兜底需要音源地址）。
      ref.read(audioPlayerProvider.notifier).suspendForBackground();
    }
  }

  Future<void> _checkAndStartLute3IfNeeded() async {
    final settings = ref.read(settingsProvider);
    if (settings.serverUrl == Settings.termuxUrl) {
      final isRunning = await TermuxService.isServerRunning(settings.serverUrl);
      if (!isRunning) {
        await TermuxService.startServer();
      }
    }
  }

  /// Checks if the server's current page matches the reader's page
  /// If they don't match, navigate to the server's page
  Future<void> _checkServerPage() async {
    if (_checkServerPageInProgress) {
      return;
    }
    _checkServerPageInProgress = true;

    final pageData = ref.read(readerProvider).pageData;
    if (pageData != null) {
      try {
        final serverPage = await ref
            .read(readerProvider.notifier)
            .getCurrentPageForBook(pageData!.bookId);

        // If we got a valid page number from server and it's different from current page
        if (serverPage != -1 && serverPage != pageData!.currentPage) {
          // Navigate to the server's page
          ref
              .read(readerProvider.notifier)
              .loadPage(
                bookId: pageData!.bookId,
                pageNum: serverPage,
                showFullPageError:
                    false, // Don't show full page error for navigation
              );
        }
      } catch (e) {
        ApiLogger.logError('checkServerPage', e);
        // Don't show error, just continue with current page
      }
    }

    _checkServerPageInProgress = false;
  }

  void _handleScrollPosition() {
    final textSettings = ref.read(textFormattingSettingsProvider);

    if (!textSettings.fullscreenMode) {
      _cancelHideTimer();
      _lastScrollPosition = _scrollController.offset;
      return;
    }

    final scrollPosition = _scrollController.offset;
    const topThreshold = 70.0;

    if (scrollPosition < topThreshold && scrollPosition < _lastScrollPosition) {
      if (!_isUiVisible) {
        _showUi();
      }
      _resetHideTimer();
    }

    _lastScrollPosition = scrollPosition;
  }

  void _showUi() {
    setState(() {
      _isUiVisible = true;
    });
    _startHideTimer();
  }

  void _hideUi() {
    setState(() {
      _isUiVisible = false;
    });
    _cancelHideTimer();
  }

  void _startHideTimer() {
    _hideUiTimer?.cancel();
    // 墨水屏下顶栏常驻，两个理由：
    // 1. 阅读屏在宽屏布局里没有任何主导航入口（底部 NavigationBar 在宽屏不出现，
    //    rail 又在阅读屏整条退场），顶栏的「书架」按钮是唯一一次点击就能离开
    //    阅读页的路径，藏起来等于把这条路又堵上；
    // 2. 显隐各是一次 0 → kToolbarHeight 的整屏 reflow，常驻反而少刷新。
    if (context.eInk) {
      // 直接赋值不走 setState：本方法会在 build 期间被调用（见下面 fullscreen
      // 分支），那里 setState 会抛异常。同文件已有同样的写法。
      _isUiVisible = true;
      return;
    }
    _hideUiTimer = Timer(const Duration(seconds: 2), _hideUi);
  }

  void _resetHideTimer() {
    _cancelHideTimer();
    _startHideTimer();
  }

  void _cancelHideTimer() {
    _hideUiTimer?.cancel();
    _hideUiTimer = null;
  }

  void _loadAudioIfNeeded() async {
    final pageData = ref.read(readerProvider).pageData;
    final settings = ref.read(settingsProvider);

    if (pageData == null || !settings.showAudioPlayer) {
      ref.read(audioPlayerProvider.notifier).reset();
      _lastAudioBookId = null;
      return;
    }

    if (_lastAudioBookId == pageData!.bookId) return;

    _lastAudioBookId = pageData!.bookId;
    // 进书默认听 MP3 音频;模式切换只在同一本书内保留。
    ref.read(playerModeProvider.notifier).setMode(PlayerMode.mp3);
    ref.read(audioPlayerProvider.notifier).reset();

    if (pageData.hasAudio) {
      final audioUrl = _audioUrlFor(settings, pageData!);
      final (bookmarks, segmentBoundaries) = _resolveAudioBookmarks(pageData!);
      debugPrint(
        'AudioPlayer load: serverBookmarks=${bookmarks?.length}, '
        'cues=${pageData!.cues.length}, segments=${segmentBoundaries.length}',
      );
      await ref
          .read(audioPlayerProvider.notifier)
          .loadAudio(
            audioUrl: audioUrl,
            bookId: pageData!.bookId,
            page: pageData!.currentPage,
            bookmarks: bookmarks,
            segmentBoundaries: segmentBoundaries,
            audioCurrentPos: pageData.audioCurrentPos,
          );
    }
  }

  /// 音频装载的两个数据源：
  /// 真书签 = 服务端同步的手动时间戳（时间轴刻度 + 书签写回的唯一内容）；
  /// 分段边界 = 循环/自动暂停/切句用的"句子"划分 —— SRT cue 起点，
  /// 无 cues 的老书签书回退为服务端书签（原有分段语义不变）。
  ///
  /// _loadAudioIfNeeded 与 AudioPlayerWidget 的构造**必须**共用这一份：
  /// widget 的 postFrame 重载按它拿到的 props 装载，两处不一致时后到的
  /// 会把先到的清掉。
  (List<double>?, List<double>) _resolveAudioBookmarks(PageData pageData) {
    final segments = pageData.cues.map((c) => c.start).toList(growable: false);
    if (segments.isNotEmpty) {
      return (pageData.audioBookmarks, segments);
    }
    return (pageData.audioBookmarks, pageData.audioBookmarks ?? const []);
  }

  /// Resolves the playable audio URL for a page.  MP3 books expose a
  /// server-relative URL via `LUTE_YT_DATA.audioUrl`; regular audio books fall
  /// back to the standard `/useraudio/stream/<bookId>` endpoint.
  String _audioUrlFor(Settings settings, PageData pageData) {
    final relative = pageData.audioUrl;
    if (relative != null && relative.isNotEmpty) {
      return '${settings.serverUrl}${relative.startsWith('/') ? '' : '/'}$relative';
    }
    return '${settings.serverUrl}/useraudio/stream/${pageData.bookId}';
  }

  /// Whether the TTS read-aloud player should be shown for the current page.
  /// Mirrors the web reader: a full timeline player bar is shown for plain text
  /// pages (no uploaded audio, no manga/image, no online video) once a TTS
  /// provider is configured.  Audio books keep the MP3 player instead —
  /// unless the user explicitly switched the bar to TTS mode.
  bool _showTtsPlayer(PageData? pageData, Settings settings) {
    if (pageData == null || !settings.showAudioPlayer) return false;
    if (pageData.isManga || pageData.isPdf || pageData.isVideoBook) {
      return false;
    }
    final ttsSettings = ref.read(ttsSettingsProvider);
    if (ttsSettings.provider == TTSProvider.none) return false;
    if (pageData.hasAudio) {
      return ref.read(playerModeProvider) == PlayerMode.tts;
    }
    return true;
  }

  /// Builds the ordered list of sentences for a text page and feeds them to the
  /// TTS player.  Called on every page load so the player always reflects the
  /// currently displayed page.
  void _loadTtsIfNeeded(PageData pageData) {
    final settings = ref.read(settingsProvider);
    if (!_showTtsPlayer(pageData, settings)) {
      _lastTtsPageKey = null;
      _stopStaleTtsPlayer();
      return;
    }
    final key = '${pageData.bookId}-${pageData.currentPage}';
    if (_lastTtsPageKey == key) return;
    _lastTtsPageKey = key;
    final sentences = _sentencesForPage(pageData);
    ref
        .read(ttsPlayerProvider.notifier)
        .loadPage(
          sentences,
          // 语言随页面一起交给播放器：播放器每句开口前推给 TTS 服务。
          // 只靠 currentBookProvider 的异步解析会输给「启动即恢复阅读」的
          // 时序（书架还没到货），日文句子就会被送去英文语音。
          bookLanguageName: _languageNameFor(_findLangId(pageData)),
        );
  }

  /// 本页朗读该用的语言名（TTS 语言标签由它换算）。
  ///
  /// 优先用 [currentBookProvider] 里已经解析好的名字；没有就从书架里同语言的
  /// 书取 `LgName` —— 那是服务端 datatables 的 JSON 字段，不依赖
  /// `/language/index` 的 HTML 解析，也就不会跟着它一起失败。
  ///
  /// 两条都拿不到就返回 null：播放器会用设置里的回退语言码，**并在播放条上
  /// 把这件事说出来**，而不是悄悄发一串注定 422 的请求。
  String? _languageNameFor(int? langId) {
    final resolved = ref.read(currentBookProvider).languageName?.trim();
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (langId == null) return null;
    try {
      final booksState = ref.read(booksProvider);
      for (final b in [
        ...booksState.activeBooks,
        ...booksState.archivedBooks,
      ]) {
        if (b.langId == langId && b.language.trim().isNotEmpty) {
          return b.language.trim();
        }
      }
    } catch (_) {
      // 书架还没就绪；语言交给 currentBookProvider 的自愈逻辑补。
    }
    return null;
  }

  /// Stops the read-aloud player when the page in front of the reader is not
  /// its page.
  ///
  /// [TTSPlayerState] carries no book, and [loadPage] is the only thing that
  /// clears it -- but a page that does not show the player (a media book, no
  /// configured provider, the bar switched off) never calls [loadPage].  The
  /// player then keeps the last book's sentence, and since sentence ids are
  /// per book, that id matches a line here: the page marks a sentence nobody
  /// is reading *and* stops following the player that is actually running,
  /// because the stale line is still in the highlighted set.
  void _stopStaleTtsPlayer() {
    if (ref.read(ttsPlayerProvider).status == TTSPlayerStatus.idle) return;
    unawaited(ref.read(ttsPlayerProvider.notifier).stop());
  }

  /// Cue the audio book's playhead is on, or -1 when there is none.
  ///
  /// An audio book's player carries a single book-wide position while the
  /// page shows a slice of the transcript, so the cue is what ties the two
  /// together -- the same link the web player's `ytCueIndex` makes.
  ///
  /// Selected rather than watched whole: the player state ticks with the
  /// playhead (a few times a second) and rebuilding this page's hundreds of
  /// word spans that often would be felt.  Only a change of cue may rebuild.
  int _audioCueIndex(PageData pageData) {
    final cues = pageData.cues;
    if (cues.isEmpty) return -1;
    return ref.watch(
      audioPlayerProvider.select(
        (player) => PlayingLine.cueIndexAt(
          cues,
          player.position.inMilliseconds / 1000.0,
        ),
      ),
    );
  }

  /// Groups the page's text items into whole sentences (preserving order).
  List<TTSPlayerSentence> _sentencesForPage(PageData pageData) {
    final order = <int>[];
    final buffers = <int, StringBuffer>{};
    for (final paragraph in pageData.paragraphs) {
      for (final item in paragraph.textItems) {
        final buffer = buffers[item.sentenceId] ??= StringBuffer();
        if (buffer.isEmpty) order.add(item.sentenceId);
        buffer.write(item.text);
      }
    }
    return [
      for (final id in order)
        TTSPlayerSentence(sentenceId: id, text: buffers[id]!.toString()),
    ];
  }

  /// Builds the shadowing panel's sentence list: the page's sentences in
  /// reading order, media books carrying a reference clip for the line
  /// (cue) each sentence sits on.
  ///
  /// Lines are runs of consecutive paragraphs sharing a paragraph number --
  /// the same split [PlayingLine] draws.  The cue map is only trusted when
  /// the line it names actually holds the cue's text (a hand-edited page
  /// must not get someone else's audio); when it does not check out the
  /// sentence simply falls back to a TTS reference.
  List<ShadowingSentence> _buildShadowingSentences(PageData pageData) {
    final paragraphs = pageData.paragraphs;
    if (paragraphs.isEmpty) return const [];

    final lines = <List<Paragraph>>[];
    for (final paragraph in paragraphs) {
      if (paragraph.textItems.isEmpty) continue;
      final paragraphId = paragraph.textItems.first.paragraphId;
      if (lines.isNotEmpty &&
          lines.last.first.textItems.first.paragraphId == paragraphId) {
        lines.last.add(paragraph);
      } else {
        lines.add([paragraph]);
      }
    }

    String norm(String text) => text.replaceAll(RegExp(r'[\s\u200b]+'), '');

    final clipPaths = List<String?>.filled(lines.length, null);
    final clipStarts = List<double?>.filled(lines.length, null);
    final clipEnds = List<double?>.filled(lines.length, null);
    final clipPath =
        ref.read(audioPlayerProvider.notifier).lastLocalAudioFile?.path;
    if (clipPath != null && pageData.pageCueMap.length == lines.length) {
      for (var k = 0; k < lines.length; k++) {
        final cueIndex = pageData.pageCueMap[k];
        if (cueIndex < 0 || cueIndex >= pageData.cues.length) continue;
        final cue = pageData.cues[cueIndex];
        final joined = lines[k].map((p) => p.fullText).join();
        if (norm(joined) == norm(cue.text)) {
          clipPaths[k] = clipPath;
          clipStarts[k] = cue.start;
          clipEnds[k] = cue.end;
        }
      }
    }

    final sentences = <ShadowingSentence>[];
    for (var k = 0; k < lines.length; k++) {
      final items = [for (final p in lines[k]) ...p.textItems];
      var start = 0;
      for (var i = 1; i <= items.length; i++) {
        if (i < items.length && items[i].sentenceId == items[start].sentenceId) {
          continue;
        }
        final group = items.sublist(start, i);
        start = i;

        final displayText = group.map((item) => item.displayText).join();
        // 空句(段落间哨兵、纯空格)不进面板:录不出也判不了。
        if (displayText.trim().isEmpty) continue;

        // 纯标点词元不参与打分:whisper 不会转写出标点,原句侧留着它们
        // 只会被标成"漏读"白扣分(Web 版把 span.word 全量上传,有同样的
        // 缺陷)。过滤后为空(整句只有标点)的句子同样剔除。
        final tokens = [
          for (final item in group)
            if (item.text.contains(_wordCharPattern)) item.text,
        ];
        if (tokens.isEmpty) continue;

        sentences.add(
          ShadowingSentence(
            sentenceId: group.first.sentenceId,
            tokens: tokens,
            languageId: group
                .map((item) => item.langId)
                .firstWhere((id) => id != null, orElse: () => null),
            displayText: displayText,
            clipPath: clipPaths[k],
            clipStart: clipStarts[k],
            clipEnd: clipEnds[k],
          ),
        );
      }
    }
    return sentences;
  }

  /// Opens the shadowing panel on the sentence currently being played (or
  /// the first sentence when nothing is).
  void _openShadowing(PageData pageData) {
    final sentences = _buildShadowingSentences(pageData);
    if (sentences.isEmpty) return;

    var initialIndex = 0;
    for (var i = 0; i < sentences.length; i++) {
      if (_shadowingSentenceIds.contains(sentences[i].sentenceId)) {
        initialIndex = i;
        break;
      }
    }

    // 录音、回放、听原句三方共用出声通道,开面板前把正在出声的全部停掉
    // -- 不止 MP3:整页 TTS 朗读、点词发音也都各占着一路声音。位置已随
    // pause 保存,关掉面板按播放就能续上。
    unawaited(ref.read(audioPlayerProvider.notifier).pause());
    unawaited(ref.read(ttsPlayerProvider.notifier).stop());
    unawaited(ref.read(sentenceTTSProvider.notifier).stop());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0x00000000),
      builder: (context) => ShadowingSheet(
        sentences: sentences,
        initialIndex: initialIndex,
      ),
    ).then((_) {
      if (mounted) {
        unawaited(ref.read(shadowingProvider.notifier).reset());
      }
    });
  }

  Future<void> reloadPage({bool forceFresh = false}) async {
    final pageData = ref.read(readerProvider).pageData;
    if (pageData != null) {
      setState(() {
        _pageKey = ValueKey('${pageData!.bookId}-${pageData!.currentPage}');
        _isLastPageMarkedDone = false;
      });
      if (forceFresh) {
        // Forcing a fresh load with no server to load from would throw away a
        // perfectly good page and replace it with a full-page error.  This is
        // reached after creating a term, which is now queued rather than
        // posted, so the page simply catches up when the term syncs.
        if (!ServerStatusManager.isReachable) return;
        await ref
            .read(readerProvider.notifier)
            .clearPageCacheForBook(pageData.bookId);
      }
      await ref
          .read(readerProvider.notifier)
          .loadPage(
            bookId: pageData.bookId,
            pageNum: pageData.currentPage,
            useCache: !forceFresh,
          );

      final langId = _findLangId(pageData);

      // 与 loadBook 同一个理由（见 current_book_provider.setBookLanguage）：
      // 底栏「Reader」走的是本方法，不补语言的话 TTS 与点词发音都只能退回
      // 设置页那个兜底语言码 —— 日文句子被送去英文语音，整页朗读无声。
      unawaited(
        ref
            .read(currentBookProvider.notifier)
            .setBookLanguage(pageData.bookId, langId),
      );

      if (langId != null) {
        unawaited(_ensureLanguageDirectionLoaded(langId));
        if (ref.read(settingsProvider).showStatsBar) {
          ref.read(termsProvider.notifier).loadStatus99Only(langId);
        }
      }

      _loadAudioIfNeeded();
      _loadTtsIfNeeded(pageData);
    }
  }

  Future<void> loadBook(int bookId, [int? pageNum]) async {
    ApiLogger.logLoading('loadBook', details: 'bookId=$bookId, page=$pageNum');
    setState(() {
      _pageKey = ValueKey('$bookId-${pageNum ?? 1}');
      _isLastPageMarkedDone = false;
      _lastAttemptedBookId = bookId;
      _lastAttemptedPageNum = pageNum;
      _lastAudioBookId = null;
    });
    try {
      await ref
          .read(readerProvider.notifier)
          .loadPage(bookId: bookId, pageNum: pageNum);

      // 恢复尝试已经有结果（正文或错误都算），之后 pageData 仍为空才是
      // 真的「没开书」，那时该显示的是空状态而不是转圈。
      _hasLoadedOnce = true;

      final pageData = ref.read(readerProvider).pageData;
      if (pageData != null) {
        final langId = _findLangId(pageData);

        // 按 id 直接加载时（启动时恢复上次在读的书）没有 Book 对象，
        // currentBookProvider 会一直是空的，朗读语言只能退回设置里的兜底
        // 语言码 —— 日文书因此被丢给英文语音，彻底没有声音。
        // 详见 CurrentBookNotifier.setBookLanguage。
        unawaited(
          ref
              .read(currentBookProvider.notifier)
              .setBookLanguage(pageData.bookId, langId),
        );

        if (langId != null) {
          unawaited(_ensureLanguageDirectionLoaded(langId));
          if (ref.read(settingsProvider).showStatsBar) {
            ref.read(termsProvider.notifier).loadStatus99Only(langId);
          }
        }
      }

      _loadAudioIfNeeded();
      if (pageData != null) {
        _loadTtsIfNeeded(pageData);
      }

      // Force rebuild to ensure UI reflects loaded book content
      if (mounted) {
        setState(() {});
      }
    } catch (e, stackTrace) {
      ApiLogger.logError('loadBook', e, stackTrace: stackTrace);

      final settings = ref.read(settingsProvider);
      if (settings.currentBookId == bookId) {
        ref.read(settingsProvider.notifier).clearCurrentBook();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('ReaderScreen', _buildCount);

    final isLoading = ref.watch(readerProvider.select((s) => s.isLoading));
    final errorMessage = ref.watch(
      readerProvider.select((s) => s.errorMessage),
    );
    final pageData = ref.watch(readerProvider.select((s) => s.pageData));
    final textSettings = ref.watch(textFormattingSettingsProvider);
    final settings = ref.watch(settingsProvider);

    // 记住「读到第几页」。冷启动时 MainNavigation 会带着这个页码恢复，reader
    // 于是直接命中本地页缓存；不带页码就得先向服务端问「读到哪了」、再拉正文
    // （两次往返 = 一个整屏转圈）。页码与 currentBookId 同源，换书时由
    // SettingsNotifier.updateCurrentBook 作废，所以这里只认当前这本书的页。
    //
    // 同时逐本记一份（BookProgressService）：SharedPreferences 里那份一换书
    // 就被作废，地铁里从书架切到昨天读过的另一本就又得联网问页码了。逐本那份
    // 按 pageData 自己的 bookId 记，不依赖 settings 是否已经跟上，所以放在
    // 上面那条「只认当前书」的守卫之前。
    ref.listen<PageData?>(readerProvider.select((s) => s.pageData), (
      previous,
      next,
    ) {
      // 取成局部非空变量：`next!.bookId` 写在 `||` 右边，短路时根本不会求值，
      // 所以它不会把 next 提升为非空 —— 后面几行照样报 nullable 错。
      if (next == null) return;
      final page = next.currentPage;
      if (page <= 0) return;

      // 语法预分析：翻页稳定 3 秒后后台跑一次整页分析（与 Grammar tab 同一个
      // 请求、同一份缓存）。词卡的 Grammar 按钮状态和句子语法页靠它秒出。
      // analyzeCurrentPage 按页去重，不会重复发；延迟 3 秒是让位给开页时的
      // 正文/词条请求。原先"仅 Grammar tab 可见才分析"的取舍在这里被刻意
      // 反转 —— 一次预分析喂三处（按钮状态、句子页、tab）。
      if (previous?.bookId == next.bookId &&
          previous?.currentPage == page) {
        return; // 同页刷新不重置计时器，否则预分析会被反复推迟。
      }
      _grammarPreAnalysisTimer?.cancel();
      if (next.paragraphs.isNotEmpty) {
        _grammarPreAnalysisTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            unawaited(
              ref.read(grammarProvider.notifier).analyzeCurrentPage(),
            );
          }
        });
      }

      if (previous?.currentPage != page || previous?.bookId != next.bookId) {
        unawaited(
          ref.read(bookProgressServiceProvider).savePage(next.bookId, page),
        );
      }

      if (next.bookId != settings.currentBookId) return;
      if (page == settings.currentBookPage) return;
      unawaited(
        ref.read(settingsProvider.notifier).updateCurrentBookPage(page),
      );
    });
    ref.watch(ttsSettingsProvider);
    final playerMode = ref.watch(playerModeProvider);
    final playerCollapsed = ref.watch(playerCollapsedProvider);
    final showTtsPlayer = _showTtsPlayer(pageData, settings);
    // 播放条的书签与分段来源，和 _loadAudioIfNeeded 共用一份派生（见
    // _resolveAudioBookmarks 的注释 —— 两处不一致会互相清空）。
    final (audioBookmarks, audioSegmentBoundaries) = pageData != null
        ? _resolveAudioBookmarks(pageData)
        : (null, const <double>[]);

    // 回到阅读屏时把实体键焦点收回来（见 _hardwareKeyFocus 的注释）。
    ref.listen<String>(currentScreenRouteProvider, (previous, next) {
      if (next == 'reader') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _hardwareKeyFocus.requestFocus();
        });
      }
    });

    // 播放条模式切换的联动:切到 TTS 时暂停 MP3 并装配当前页的朗读句子;
    // 切回 MP3 时停掉朗读条。两边都不自动发声,等用户按播放。
    ref.listen<PlayerMode>(playerModeProvider, (previous, next) {
      if (previous == next) return;
      if (next == PlayerMode.tts) {
        unawaited(ref.read(audioPlayerProvider.notifier).pause());
        _lastTtsPageKey = null;
        if (pageData != null) {
          _loadTtsIfNeeded(pageData);
        }
      } else {
        _stopStaleTtsPlayer();
      }
    });

    if (textSettings.fullscreenMode && !_lastFullscreenMode) {
      _lastFullscreenMode = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _startHideTimer();
    } else if (!textSettings.fullscreenMode && _lastFullscreenMode) {
      _lastFullscreenMode = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _cancelHideTimer();
      _isUiVisible = true;
    }

    // Check if reader is the active screen
    final isVisible = ref.watch(currentScreenRouteProvider) == 'reader';

    return HardwareKeyNavigator(
      // 只在墨水屏模式接管物理键：手机上音量键就该去管音量。
      enabled: context.eInk,
      focusNode: _hardwareKeyFocus,
      onAction: (action) => _handleHardwareKey(action, pageData),
      child: AbsorbPointer(
        absorbing: !isVisible,
        child: Scaffold(
          appBar: _buildAppBar(
            context,
            pageData,
            textSettings.fullscreenMode,
            ref.watch(serverStatusProvider).isReachable,
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  if (settings.showAudioPlayer &&
                      pageData?.hasAudio == true &&
                      playerMode == PlayerMode.mp3 &&
                      !playerCollapsed)
                    AnimatedContainer(
                      duration: einkDuration(
                        const Duration(milliseconds: 200),
                        eInk: context.eInk,
                      ),
                      curve: Curves.easeInOut,
                      margin: EdgeInsets.only(
                        top: textSettings.fullscreenMode && !_isUiVisible
                            ? MediaQuery.of(context).padding.top +
                                  kToolbarHeight
                            : 0,
                      ),
                      child: AudioPlayerWidget(
                        audioUrl: _audioUrlFor(settings, pageData!),
                        bookId: pageData!.bookId,
                        page: pageData!.currentPage,
                        bookmarks: audioBookmarks,
                        segmentBoundaries: audioSegmentBoundaries,
                        audioCurrentPos: pageData.audioCurrentPos,
                        onShadowing: pageData!.paragraphs.isEmpty
                            ? null
                            : () => _openShadowing(pageData!),
                      ),
                    ),
                  if (showTtsPlayer && !playerCollapsed)
                    AnimatedContainer(
                      duration: einkDuration(
                        const Duration(milliseconds: 200),
                        eInk: context.eInk,
                      ),
                      curve: Curves.easeInOut,
                      margin: EdgeInsets.only(
                        top: textSettings.fullscreenMode && !_isUiVisible
                            ? MediaQuery.of(context).padding.top +
                                  kToolbarHeight
                            : 0,
                      ),
                      child: TTSPlayerWidget(
                        showMp3Toggle: pageData?.hasAudio == true,
                        onShadowing: (pageData?.paragraphs.isEmpty ?? true)
                            ? null
                            : () => _openShadowing(pageData!),
                      ),
                    ),
                  Expanded(
                    child: _buildBody(isLoading, errorMessage, pageData),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 阅读屏的抽屉就是 Reader Settings 面板（排版区在顶），汉堡和 Aa 都开它：
  /// Aa 是高频动作的显性入口，点进去第一屏就是字体字号。
  void _openReaderDrawer() {
    widget.scaffoldKey?.currentState?.openDrawer();
  }

  /// 当前页是否有播放条可显示（漫画/视频书、未配置 TTS、播放条总开关关闭
  /// 时为 false）。与 body 里两条播放条的显示条件保持一致。
  bool _playerAvailable(PageData? pageData, Settings settings) {
    if (settings.showAudioPlayer &&
        pageData?.hasAudio == true &&
        ref.read(playerModeProvider) == PlayerMode.mp3) {
      return true;
    }
    return _showTtsPlayer(pageData, settings);
  }

  /// AppBar 上的播放条收起/恢复快捷按钮。
  ///
  /// 收起只藏 UI：播放状态都在 provider 里，朗读/音乐继续、句子高亮跟随
  /// 照旧。已收起时按钮显示当前模式的图标，提示有播放在进行、点击恢复。
  Widget _buildPlayerToggleButton(PageData? pageData, Settings settings) {
    final collapsed = ref.watch(playerCollapsedProvider);
    final mp3Mode =
        pageData?.hasAudio == true &&
        ref.read(playerModeProvider) == PlayerMode.mp3;
    return IconButton(
      icon: Icon(
        collapsed
            ? (mp3Mode ? Icons.music_note : Icons.record_voice_over)
            : Icons.keyboard_arrow_up,
      ),
      tooltip: collapsed ? 'Show player' : 'Collapse player',
      onPressed: () => ref
          .read(playerCollapsedProvider.notifier)
          .setCollapsed(!collapsed),
    );
  }

  /// 阅读屏顶栏的「书架」直达入口。
  ///
  /// 阅读屏是 IndexedStack 的一个 tab，不是 push 出来的页面，所以"返回"只能靠
  /// 主导航切 tab。而主导航在阅读屏上一条都不剩：窄屏的底部 NavigationBar 在
  /// 宽屏不渲染（app.dart:562），宽屏的 rail 又在阅读屏整条退场
  /// （app.dart:662）。Leaf 5C 逻辑宽约 674dp、走宽屏分支，于是离开阅读页只剩
  /// 汉堡 → 抽屉 → Books 三次操作 —— 这就是"没有跳回 book 页面的便捷方式"。
  ///
  /// 给阅读屏恢复一条常驻导航要吃掉正文行宽，代价太大；一个一次点击的按钮就够。
  /// （原先想让它顶掉 Grammar 按钮，真机上不成立 —— 见 `_buildGrammarButton`。）
  Widget _buildBooksButton() {
    // 窄屏不渲染：底栏常驻（Reader|Books|Grammar|Review|Stats），Books 入口
    // 齐全，这个直达按钮是给宽屏（rail 在阅读屏退场）准备的。窄屏还渲染它
    // 会把 actions 行挤出屏 —— actions 靠右对齐但超宽时向左延伸，第一个
    // action 正好压在 leading 汉堡上（PHB110 逻辑宽 360dp 实测重叠，见
    // uiautomator bounds：books [38,176][230,368] 盖住 leading [0,160][224,384]）。
    // 阈值与 app.dart 的 _wideLayoutMinWidth 保持一致。
    if (MediaQuery.sizeOf(context).width < 600) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.collections_bookmark),
      tooltip: 'Books',
      onPressed: () => ref.read(navigationProvider).navigateToScreen('books'),
    );
  }

  /// 阅读屏顶栏的「语法」入口，打开 Grammar 分析页（当前页的语法点）。
  ///
  /// 2026-09-26 做书架入口时把它撤了（"拼写检查不是阅读动作"），真机上很快
  /// 被找回来：宽屏阅读页没有 rail，抽屉是 Grammar 唯一的路，而抽屉是整屏
  /// 覆盖。位置紧挨 `Aa` —— 两者都是"对正文做的事"，一起放在同一侧。
  ///
  /// 窄屏不渲染：底栏常驻（Reader|Books|Grammar|Review|Stats）已经有一个
  /// Grammar tab，同一个动作不该上下各出一遍。顺带也解掉顶栏拥挤 —— 窄屏
  /// actions 本就超宽，这一个 48dp 正好把最左边的离线云徽标挤到 leading
  /// 汉堡上（与 _buildBooksButton 同一处阈值、同一个原因）。
  Widget _buildGrammarButton() {
    if (MediaQuery.sizeOf(context).width < 600) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.spellcheck),
      tooltip: 'Grammar',
      onPressed: () => ref.read(navigationProvider).navigateToScreen('grammar'),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    PageData? pageData,
    bool fullscreenMode,
    bool serverReachable,
  ) {
    final settings = ref.read(settingsProvider);

    if (fullscreenMode) {
      final topPadding = MediaQuery.of(context).padding.top;
      return PreferredSize(
        preferredSize: Size.fromHeight(
          _isUiVisible ? kToolbarHeight + topPadding : 0,
        ),
        child: AnimatedContainer(
          duration: einkDuration(
            const Duration(milliseconds: 200),
            eInk: context.eInk,
          ),
          curve: Curves.easeInOut,
          height: _isUiVisible ? kToolbarHeight + topPadding : 0,
          child: AppBar(
            leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
            title: Text(pageData?.title ?? 'Reader'),
            actions: [
              OutboxStatusIndicator(serverReachable: serverReachable),
              _buildBooksButton(),
              if (_playerAvailable(pageData, settings))
                _buildPlayerToggleButton(pageData, settings),
              if (pageData?.isManga == true)
                IconButton(
                  icon: Icon(
                    _mangaRevealAll ? Icons.visibility : Icons.visibility_off,
                  ),
                  tooltip: _mangaRevealAll
                      ? 'Hide all text overlays'
                      : 'Reveal all text overlays',
                  onPressed: () =>
                      setState(() => _mangaRevealAll = !_mangaRevealAll),
                ),
              IconButton(
                icon: const Icon(Icons.text_fields),
                tooltip: 'Text formatting',
                onPressed: _openReaderDrawer,
              ),
              _buildGrammarButton(),
              if (pageData != null && pageData.pageCount > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: pageData!.currentPage > 1
                            ? () => _loadPageWithoutMarkingRead(
                                pageData!.currentPage - 1,
                              )
                            : null,
                        tooltip: 'Previous page',
                      ),
                      if (settings.showPageNumbers)
                        GestureDetector(
                          onDoubleTap: () => _showPageNavigationSlider(),
                          onLongPress: () => _showPageNavigationSlider(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: Text(pageData.pageIndicator),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: pageData!.currentPage < pageData.pageCount
                            ? () => _loadPageWithoutMarkingRead(
                                pageData!.currentPage + 1,
                              )
                            : null,
                        tooltip: 'Next page',
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return AppBar(
      leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
      title: Text(pageData?.title ?? 'Reader'),
      actions: [
        OutboxStatusIndicator(serverReachable: serverReachable),
        _buildBooksButton(),
        if (_playerAvailable(pageData, settings))
          _buildPlayerToggleButton(pageData, settings),
        if (pageData?.isManga == true)
          IconButton(
            icon: Icon(
              _mangaRevealAll ? Icons.visibility : Icons.visibility_off,
            ),
            tooltip: _mangaRevealAll
                ? 'Hide all text overlays'
                : 'Reveal all text overlays',
            onPressed: () =>
                setState(() => _mangaRevealAll = !_mangaRevealAll),
          ),
        if (pageData?.isManga == true)
          IconButton(
            icon: Icon(
              _mangaFitToScreen ? Icons.fit_screen : Icons.fullscreen,
            ),
            tooltip: _mangaFitToScreen
                ? 'Fit page to width'
                : 'Fit page to screen',
            onPressed: () =>
                setState(() => _mangaFitToScreen = !_mangaFitToScreen),
          ),
        IconButton(
          icon: const Icon(Icons.text_fields),
          tooltip: 'Text formatting',
          onPressed: _openReaderDrawer,
        ),
        _buildGrammarButton(),
        if (pageData != null && pageData.pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: pageData!.currentPage > 1
                      ? () => _loadPageWithoutMarkingRead(
                          pageData!.currentPage - 1,
                        )
                      : null,
                  tooltip: 'Previous page',
                ),
                if (settings.showPageNumbers)
                  GestureDetector(
                    onDoubleTap: () => _showPageNavigationSlider(),
                    onLongPress: () => _showPageNavigationSlider(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(pageData.pageIndicator),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: pageData!.currentPage < pageData.pageCount
                      ? () => _loadPageWithoutMarkingRead(
                          pageData!.currentPage + 1,
                        )
                      : null,
                  tooltip: 'Next page',
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStatsRow() {
    final pageData = ref.read(readerProvider).pageData;

    int? langId;
    if (pageData != null) {
      for (final paragraph in pageData.paragraphs) {
        for (final textItem in paragraph.textItems) {
          if (textItem.langId != null) {
            langId = textItem.langId;
            break;
          }
        }
        if (langId != null) break;
      }
    }

    final languageName = langId != null
        ? (_languageIdToName[langId] ?? '')
        : '';
    if (languageName.isEmpty) {
      return const SizedBox.shrink();
    }
    if (langId != null && langId != _lastStatsLangId) {
      _lastStatsLangId = langId;
      if (ref.read(settingsProvider).showStatsBar) {
        ref.read(termsProvider.notifier).loadStatus99Only(langId);
      }
    }

    return Consumer(
      builder: (context, ref, _) {
        final termsState = ref.watch(termsProvider);
        final statsState = ref.watch(statsProvider);

        final languageFlag = getFlagForLanguage(languageName) ?? '';

        int todayWordcount = 0;
        int status99Count = termsState.stats.status99;

        if (statsState.value != null) {
          final today = DateTime.now();

          for (final langStats in statsState.value!.languages) {
            if (langStats.language == languageName) {
              final todayStats = langStats.dailyStats.firstWhere(
                (s) =>
                    s.date.year == today.year &&
                    s.date.month == today.month &&
                    s.date.day == today.day,
                orElse: () => DailyReadingStats(
                  date: today,
                  wordcount: 0,
                  runningTotal: 0,
                ),
              );
              todayWordcount = todayStats.wordcount;
              break;
            }
          }
        }

        final theme = Theme.of(context);
        final showKnownTermsCount = ref
            .read(settingsProvider)
            .showKnownTermsCount;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (languageFlag.isNotEmpty) ...[
                Text(languageFlag, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
              ],
              Text(
                "Today's Words: $todayWordcount",
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              if (showKnownTermsCount)
                Text("Known: $status99Count", style: theme.textTheme.bodySmall),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPageControls(BuildContext context, PageData pageData) {
    final isLastPage = pageData!.currentPage == pageData.pageCount;
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final showStatsBar = settings.showStatsBar;

    return Align(
      alignment: Alignment.centerRight,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline, size: 20),
                        SizedBox(width: 4),
                        Text('All Known'),
                      ],
                    ),
                    onPressed: () => _markPageKnown(),
                    tooltip: 'All Known',
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: pageData!.currentPage > 1
                        ? () => _goToPage(pageData!.currentPage - 1)
                        : null,
                    tooltip: 'Previous page',
                  ),
                  if (settings.showPageNumbers)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        pageData.pageIndicator,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  if (isLastPage)
                    IconButton(
                      icon: Icon(
                        Icons.check,
                        color: _isLastPageMarkedDone
                            ? theme.colorScheme.primary
                            : null,
                      ),
                      onPressed: () => _markLastPageDone(pageData),
                      tooltip: 'Mark as done',
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _goToPage(pageData!.currentPage + 1),
                      tooltip: 'Next page',
                    ),
                ],
              ),
              if (showStatsBar) _buildStatsRow(),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, String>? _mangaImageHeaders(Settings settings) {
    final headers = SessionManager.authHeaders();
    if (headers.isEmpty) return null;
    return headers;
  }

  /// 是否正在恢复「上次在读的书」：settings 里记着这本书，但本次运行还没
  /// 为它拿到结果（正文或错误），正文还没到。
  ///
  /// 这段窗口里页面是空的，但**不是**「没开书」：冷启动时正文来自本地页
  /// 缓存，只差一两帧；显示 "No Book Loaded" 会误导用户。
  bool _isRestoringBook(Settings settings) {
    final bookId = settings.currentBookId;
    if (bookId == null || _hasLoadedOnce) return false;
    // 加载还没发起（_lastAttemptedBookId 仍为 null）也算「恢复中」：
    // MainNavigation 的启动恢复就在这一两帧里由 post-frame 回调发起。
    return _lastAttemptedBookId == null || _lastAttemptedBookId == bookId;
  }

  Widget _buildBody(bool isLoading, String? errorMessage, PageData? pageData) {
    final settings = ref.watch(settingsProvider);

    // 转圈延迟显示：启动恢复走本地页缓存，通常一两帧就位；立刻画进度圈
    // 会让每次冷启动都闪一下 loading。真的慢（缓存未命中 → 走网络）时才显示。
    if (isLoading) {
      return const _DeferredLoadingIndicator(message: 'Loading content...');
    }

    if (!settings.isUrlValid) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                size: 64,
                color: context.appColorScheme.text.secondary,
              ),
              const SizedBox(height: 16),
              Text(
                'No Server Connection',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Please configure your Song server in settings.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(navigationProvider).navigateToScreen('settings'),
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
              ),
            ],
          ),
        ),
      );
    }

    if (errorMessage != null) {
      final bookId = pageData?.bookId ?? _lastAttemptedBookId;
      final pageNum = pageData?.currentPage ?? _lastAttemptedPageNum;

      return ErrorDisplay(
        message: errorMessage,
        onRetry: bookId != null
            ? () {
                ref.read(readerProvider.notifier).clearError();
                ref
                    .read(readerProvider.notifier)
                    .loadPage(bookId: bookId, pageNum: pageNum);
              }
            : null,
      );
    }

    if (pageData == null) {
      // 正在恢复上次在读的书（settings 里记着这本书，正文还在路上）：
      // 这时显示 "No Book Loaded" 是错的 —— 书是有的，只是还没读出来。
      if (_isRestoringBook(settings)) {
        return const _DeferredLoadingIndicator(message: 'Loading content...');
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.menu_book,
                size: 64,
                color: context.appColorScheme.text.secondary,
              ),
              const SizedBox(height: 16),
              Text(
                'No Book Loaded',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Select a book from the books screen to start reading.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(navigationProvider).navigateToScreen('books'),
                icon: const Icon(Icons.collections_bookmark),
                label: const Text('Browse Books'),
              ),
            ],
          ),
        ),
      );
    }

    final textSettings = ref.watch(textFormattingSettingsProvider);
    final langId = _findLangId(pageData);
    final textDirection = langId != null
        ? _languageIdToDirection[langId]
        : null;

    if (langId != null && textDirection == null) {
      unawaited(_ensureLanguageDirectionLoaded(langId));
    }

    final hasGestureNav = MediaQuery.of(context).systemGestureInsets.bottom > 0;

    // Sentence the read-aloud player is on, marked in the page text the way
    // the web reader does it (LutePlayingLine).  Selected rather than watched
    // whole: the player state ticks every 250 ms with the playhead, and
    // rebuilding this page's hundreds of word spans that often would be
    // felt.  Only a sentence change, or the player starting/stopping, may
    // rebuild.  Nothing is marked while the player is idle or failed --
    // there is no line being read then.
    final ttsSentenceId = ref.watch(
      ttsPlayerProvider.select((player) {
        switch (player.status) {
          case TTSPlayerStatus.playing:
          case TTSPlayerStatus.loading:
          case TTSPlayerStatus.paused:
            return player.currentSnippet?.sentenceId;
          case TTSPlayerStatus.idle:
          case TTSPlayerStatus.error:
            return null;
        }
      }),
    );

    // The media players (MP3 / YouTube / Bilibili) do not speak sentences:
    // they play subtitle cues, and what gets marked is the *line* holding the
    // cue the playhead is on -- the web reader's `ytMarkPlayingLine`, resolved
    // against the same `LUTE_PAGE_CUE_MAP` the server renders with the page.
    // A cue that is not on the page being read marks nothing, which is the
    // honest answer while the reader is somewhere else in the book.
    final playingCueIndex = pageData.isVideoBook
        ? _activeCueIndex
        : _audioCueIndex(pageData);
    final highlightedSentenceIds = <int>{
      ?ttsSentenceId,
      if (playingCueIndex >= 0 && playingCueIndex < pageData.cues.length)
        ...PlayingLine.sentenceIdsForCue(
          paragraphs: pageData.paragraphs,
          pageCueMap: pageData.pageCueMap,
          cueIndex: playingCueIndex,
          cueText: pageData.cues[playingCueIndex].text,
        ),
    };
    // 影子跟读面板打开时拿不到 watch 上下文,当前句以这里最近一次算出的
    // 高亮句为准(每次 build 都刷新,面板一开就是"正在播的那句")。
    _shadowingSentenceIds = highlightedSentenceIds;

    final textDisplay = TextDisplay(
      key: _pageKey,
      paragraphs: pageData.paragraphs,
      scrollController: _scrollController,
      topPadding: textSettings.fullscreenMode && !_isUiVisible
          ? MediaQuery.of(context).padding.top * 0.5
          : 0.0,
      bottomPadding: hasGestureNav ? 128 : 0,
      bottomControlWidget: _buildPageControls(context, pageData),
      onTap: (item, context) {
        _handleTap(item, context);
      },
      onDoubleTap: (item) {
        _handleDoubleTap(item);
      },
      onLongPress: (item) {
        _handleLongPress(item);
      },
      onMultiTermSelectionStart: _handleMultiTermSelectionStart,
      onMultiTermSelectionComplete: (selectedItems) {
        unawaited(_handleMultiTermSelectionComplete(selectedItems));
      },
      onTripleTap: (item) {
        _handleTripleTap(item);
      },
      enableTripleTap: settings.enableTripleTapToMarkKnown,
      doubleTapTimeout: settings.doubleTapTimeout,
      textSize: textSettings.textSize,
      lineSpacing: textSettings.lineSpacing,
      fontFamily: textSettings.fontFamily,
      fontWeight: textSettings.fontWeight,
      isItalic: textSettings.isItalic,
      textDirection: textDirection,
      highlightedWordId: _highlightedWordId,
      highlightedParagraphId: _highlightedParagraphId,
      highlightedOrder: _highlightedOrder,
      highlightedSentenceIds: highlightedSentenceIds,
    );

    final mangaPage = pageData.mangaPage;
    final pdfPage = pageData.pdfPage;
    final content = mangaPage != null
        ? MangaPageView(
            key: _pageKey,
            manga: mangaPage,
            imageUrl: '${settings.serverUrl}${mangaPage.imagePath}',
            imageHeaders: _mangaImageHeaders(settings),
            revealAll: _mangaRevealAll,
            fitToScreen: _mangaFitToScreen,
            onTurnPage: (forward) =>
                _turnPage(forward ? -1 : 1, pageData),
            onTap: (item, context) {
              _handleTap(item, context);
            },
            onDoubleTap: (item) {
              _handleDoubleTap(item);
            },
            onLongPress: (item) {
              _handleLongPress(item);
            },
            onTripleTap: (item) {
              _handleTripleTap(item);
            },
            fontFamily: textSettings.fontFamily,
            fontWeight: textSettings.fontWeight,
            isItalic: textSettings.isItalic,
          )
        : pdfPage != null
        ? PdfPageView(
            key: _pageKey,
            bookId: pageData.bookId,
            pdf: pdfPage,
            pdfUrl: '${settings.serverUrl}${pdfPage.pdfPath}',
            pdfHeaders: _mangaImageHeaders(settings),
            onTurnPage: (forward) =>
                _turnPage(forward ? -1 : 1, pageData),
            onTap: (item, context) {
              _handleTap(item, context);
            },
            onLongPress: (item) {
              _handleLongPress(item);
            },
          )
        : textDisplay;

    // Online video player (YouTube or Bilibili): rendered above the
    // subtitle text and kept outside the page-transitioned subtree (keyed
    // by book id) so it keeps playing while the user turns pages.  The
    // position is saved to the server on a timer.
    final youtube = pageData.youtube;
    final bilibili = pageData.bilibili;
    final youtubePlayer = (youtube != null || bilibili != null)
        ? Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: YoutubePlayerView(
              key: ValueKey('yt-${pageData.bookId}'),
              videoId: youtube?.videoId,
              startPos: youtube?.startPos ?? bilibili?.startPos ?? 0,
              bookId: pageData.bookId,
              cues: youtube?.cues ?? bilibili?.cues ?? const [],
              bilibili: bilibili,
              serverUrl: settings.serverUrl,
              onPositionChanged: (bookId, position) {
                ref
                    .read(readerRepositoryProvider)
                    .contentService
                    .saveYoutubePlayerData(bookId, position);
              },
              onActiveCueChanged: (cueIndex) {
                if (cueIndex == _activeCueIndex) return;
                setState(() {
                  _activeCueIndex = cueIndex;
                });
              },
            ),
          )
        : null;

    return Stack(
      children: [
        Column(
          children: [
            if (youtubePlayer != null) youtubePlayer,
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (scrollNotification) {
                  if (scrollNotification is ScrollUpdateNotification) {
                    if (scrollNotification.scrollDelta != null &&
                        scrollNotification.scrollDelta!.abs() > 5) {
                      TermTooltipClass.close();
                    }
                  }
                  return false;
                },
                child: GestureDetector(
                  onTapDown: (details) {
                    _lastTapX = details.globalPosition.dx;
                    TermTooltipClass.close();
                  },
                  onTap: () {
                    // 墨水屏模式：点左三分之一上一页、右三分之一下一页，中间区域
                    // 仍走原来的「唤出/续期 UI」。拖动翻页在这里是关掉的（见
                    // onHorizontalDragStart）—— 跟手位移每一帧都要刷一次屏。
                    if (context.eInk) {
                      final width = MediaQuery.sizeOf(context).width;
                      if (_lastTapX < width / 3) {
                        _turnPage(1, pageData);
                        return;
                      }
                      if (_lastTapX > width * 2 / 3) {
                        _turnPage(-1, pageData);
                        return;
                      }
                    }
                    if (textSettings.fullscreenMode) {
                      if (!_isUiVisible) {
                        _showUi();
                      } else {
                        _resetHideTimer();
                      }
                    }
                  },
                  // 漫画页必须给拖动识别器传 null（而不是让处理器提前
                  // return）：HorizontalDragGestureRecognizer 只要参与手势
                  // 竞技场，就会在横向位移超过 slop 时抢先判赢，Interactive
                  // Viewer 的缩放识别器被整个拒掉 —— 双指捏合永远失灵。
                  // 漫画页的横向快滑翻页由 MangaPageView 内部自己检测。
                  onHorizontalDragStart: pageData.isManga || pageData.isPdf
                      ? null
                      : (details) {
                          // 墨水屏下不跟手：拖动过程中的每一帧位移都是一次全屏刷新。
                          // 翻页改走左右区域点击（见 onTap）。
                          if (context.eInk) return;
                          if (!_canSwipePages(pageData)) return;
                          _isDragActive = true;
                        },
                  onHorizontalDragUpdate: pageData.isManga || pageData.isPdf
                      ? null
                      : (details) {
                          if (!_isDragActive) return;
                          setState(() {
                            _dragOffset += details.delta.dx;
                          });
                        },
                  onHorizontalDragCancel: pageData.isManga || pageData.isPdf
                      ? null
                      : () {
                          if (!_isDragActive) return;
                          setState(() {
                            _isDragActive = false;
                            _dragOffset = 0;
                          });
                        },
                  onHorizontalDragEnd: pageData.isManga || pageData.isPdf
                      ? null
                      : (details) async {
                    final wasDragging = _isDragActive;
                    _isDragActive = false;
                    final dragOffset = _dragOffset;
                    // 先归零，触发平滑回弹/滑出（见下方 TweenAnimationBuilder）。
                    if (dragOffset != 0) {
                      setState(() {
                        _dragOffset = 0;
                      });
                    }
                    if (!wasDragging) return;

                    final velocity = details.primaryVelocity ?? 0;
                    const minSwipeVelocity = 300.0;
                    // 位移阈值：屏宽的 18%。
                    // 原先只看甩动速度，导致「慢慢拖过半个屏幕再松手」也不翻页，
                    // 与直觉严重不符 —— 这是翻页手感生硬的主要原因之一。
                    final distanceThreshold =
                        MediaQuery.sizeOf(context).width * 0.18;

                    // 方向判定：优先看甩动速度；速度不足时退回看拖动位移。
                    int direction = 0;
                    if (velocity.abs() >= minSwipeVelocity) {
                      direction = velocity > 0 ? 1 : -1;
                    } else if (dragOffset.abs() >= distanceThreshold) {
                      direction = dragOffset > 0 ? 1 : -1;
                    }
                    _turnPage(direction, pageData);
                  },
                  child: TweenAnimationBuilder<double>(
                    // 拖动中 duration 为 0（立即跟手），松手后 200ms 平滑回弹/滑出。
                    tween: Tween<double>(begin: 0, end: _dragOffset),
                    duration: _isDragActive
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    builder: (context, value, child) => Transform.translate(
                      offset: Offset(value, 0),
                      child: child,
                    ),
                    // 墨水屏下连转场也不要：它是一段 200ms 的补间，等于十几帧全刷。
                    child: settings.pageTurnAnimations && !context.eInk
                        ? _PageTransition(
                            isForward: _isNavigatingForward,
                            child: content,
                          )
                        : content,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (hasGestureNav)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 48,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) {},
              onVerticalDragUpdate: (_) {},
              onVerticalDragEnd: (_) {},
              onTap: () {
                if (textSettings.fullscreenMode && !_isUiVisible) {
                  _showUi();
                }
              },
              child: const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  void _handleTap(TextItem item, BuildContext context) async {
    if (item.isSpace) return;

    // Answer the finger before the network does.  The card cannot be shown
    // until a fetch returns, and the buzz used to happen only after that fetch
    // (or not at all when it failed), which is what made a tap read as ignored.
    // The web reader has the same rule: _tap_press answers on touchstart.
    HapticFeedback.lightImpact();

    TermTooltipClass.close();

    try {
      if (item.wordId == null) return;

      final seq = ++_tooltipSeq;

      final renderBox = context.findRenderObject() as RenderBox;
      final termRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;

      final termTooltip = await ref
          .read(readerProvider.notifier)
          .fetchTermTooltip(item.wordId!);
      // Superseded while we waited: a second tap began a double tap (which runs
      // its own feedback and closes this card), or moved on to another word.
      // Drawing now would stack this card on top of the newer gesture.
      if (seq != _tooltipSeq) return;
      // A null fetch (offline, or the request failed) no longer means silence:
      // fall back to a minimal card built from local data. A successful but
      // empty popup still means "no card" -- that is the server's answer.
      final tooltip = termTooltip != null && termTooltip.hasData
          ? termTooltip
          : termTooltip == null
          ? await ref
                .read(readerProvider.notifier)
                .buildLocalTooltipFallback(item)
          : null;
      if (seq != _tooltipSeq) return;
      if (tooltip != null && mounted) {
        final langId = item.langId;
        // An annotated reading (romanization) outranks the surface form for
        // TTS -- the engine pronounces the reading the user wrote down.
        final speakText = ttsSpeakTextForTerm(
          term: tooltip.term,
          reading: tooltip.romanization,
        );
        // Auto pronounce (Settings -> Reading): read the term as the card opens,
        // so the reader does not have to reach for the speaker button.
        if (ref.read(settingsProvider).autoPronounceOnTap) {
          unawaited(
            ref.read(sentenceTTSProvider.notifier).speakSentence(speakText, 0),
          );
        }
        // Grammar button state comes from the page pre-analysis: it knows
        // whether this sentence matched anything.  no -> greyed out; yes ->
        // tappable and the grammar page opens instantly; unknown (page not
        // analysed yet, or the analysis failed) -> keep tappable and let the
        // sentence-level request answer.
        final sentence = _extractSentence(item);
        final grammarPresence = sentence.isEmpty
            ? GrammarPresence.unknown
            : ref
                  .read(sentenceGrammarProvider.notifier)
                  .presenceFor(sentence);
        TermTooltipClass.show(
          context,
          tooltip,
          termRect,
          onSpeak: () => unawaited(
            ref.read(sentenceTTSProvider.notifier).speakSentence(speakText, 0),
          ),
          onSentenceTranslation: langId == null
              ? null
              : () => _translateSentenceFromCard(item, langId),
          onGrammar: sentence.isEmpty
              ? null
              : () => _openSentenceGrammar(sentence),
          grammarEnabled: grammarPresence != GrammarPresence.no,
        );
      }
    } catch (e) {
      return;
    }
  }

  /// Sentence translation, entered from the button on the word card.
  ///
  /// The card goes first: the translation is a modal sheet, and a card left
  /// behind in the overlay would float above it.
  void _translateSentenceFromCard(TextItem item, int langId) {
    final sentence = _extractSentence(item);
    if (sentence.isEmpty) return;
    TermTooltipClass.close();
    _showSentenceTranslation(sentence, langId);
  }

  /// Sentence grammar, entered from the button on the word card.
  ///
  /// The card goes first for the same reason as the translation: the grammar
  /// screen is pushed onto the navigator, and the card lives in the root
  /// overlay, which would otherwise float above it.
  void _openSentenceGrammar(String sentence) {
    final page = ref.read(readerProvider).pageData;
    if (page == null) return;
    TermTooltipClass.close();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SentenceGrammarScreen(
          sentenceText: sentence,
          bookId: page.bookId,
          pageNum: page.currentPage,
        ),
      ),
    );
  }

  /// Double tap on a word: cycle its status 1 -> 3 -> 99 -> 1.
  ///
  /// Mirrors the web reader's Quick Set Status Mode double tap
  /// (_quick_cycle_status in lute-touch.js).  A word that is not on the cycle yet
  /// -- status 0, or one of the skipped 2/4/5 -- enters at 1, as the web does.
  void _handleDoubleTap(TextItem item) {
    final wordId = item.wordId;
    if (wordId == null) return;

    // Supersede the card the pair's first tap may still be fetching (see
    // _tooltipSeq): otherwise it lands on top of the status change.
    _tooltipSeq++;
    TermTooltipClass.close();

    final current =
        RegExp(r'status(\d+)').firstMatch(item.statusClass)?.group(1) ?? '0';
    final idx = _statusCycle.indexOf(current);
    final next = idx == -1
        ? _statusCycle.first
        : _statusCycle[(idx + 1) % _statusCycle.length];

    // Same guard as the web: a word already carrying this status gets no write.
    if (next == current) return;

    HapticFeedback.mediumImpact();

    ApiLogger.logState(
      '_handleDoubleTap',
      details: 'wordId=$wordId, $current -> $next',
    );

    // Repaint immediately.  The write below is a fetch-then-post, far too slow to
    // gate the colour on, and the web reader's status swap is just as eager.
    unawaited(ref.read(readerProvider.notifier).updateTermStatus(wordId, next));

    _originalTextItem = item;
    _triggerWordGlow();

    // Hand the intent to the outbox instead of posting it from here.  The
    // write is now a local Hive record, so a tap with no signal is
    // acknowledged instantly and replayed when the link returns -- the old
    // path fetched the term form and POSTed it inline, which is why a tap in
    // the subway ended in "Could not update status" and a reverted colour.
    //
    // No per-word serialisation is needed any more: the outbox keeps at most
    // one intent per term and the newest status wins, so two rapid cycles
    // collapse onto whatever status the user actually landed on.
    unawaited(
      ref
          .read(outboxProvider.notifier)
          .enqueueTermStatus(wordId, next, langId: item.langId),
    );
  }

  void _triggerWordGlow() {
    final settings = ref.read(termFormSettingsProvider);

    // Only trigger if enabled and we have an original text item
    if (!settings.wordGlowEnabled || _originalTextItem == null) return;

    // Cancel any existing timer
    _glowTimer?.cancel();

    // Set highlight for this specific instance
    setState(() {
      _highlightedWordId = _originalTextItem!.wordId;
      _highlightedParagraphId = _originalTextItem!.paragraphId;
      _highlightedOrder = _originalTextItem!.order;
    });

    // Auto-dismiss after 150ms
    _glowTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _highlightedWordId = null;
          _highlightedParagraphId = null;
          _highlightedOrder = null;
        });
      }
    });
  }

  /// Long press on a single word opens its term edit form.
  ///
  /// This is the web reader's Quick Set Status Mode gesture
  /// (show_term_edit_form in lute-touch.js): a long press is what reaches the
  /// form.  Reached from the reader text, the manga overlay, and the end of a
  /// one-word multi-select.
  void _handleLongPress(TextItem item) {
    _openTermForm(item);
  }

  /// Fetch a word's term data and open the edit form for it.
  ///
  /// The form is built from what the server returns, so a round trip happens
  /// before the sheet appears; the long-press haptics in text_display.dart cover
  /// that wait.
  Future<void> _openTermForm(TextItem item) async {
    final wordId = item.wordId;
    if (wordId == null) return;
    final seq = ++_termFormSeq;
    try {
      final termForm = await ref
          .read(readerProvider.notifier)
          .fetchTermFormById(wordId);
      // Superseded while we waited: a later long press already owns the sheet.
      if (termForm == null || !mounted || seq != _termFormSeq) return;
      _showTermForm(
        termForm,
        sentence: _extractSentence(item),
        initialReaderStatus: RegExp(
          r'status(\d+)',
        ).firstMatch(item.statusClass)?.group(1),
      );
    } catch (e) {
      ApiLogger.logError('_openTermForm', e, details: 'wordId=$wordId');
    }
  }

  void _handleMultiTermSelectionStart() {
    TermTooltipClass.close();
    setState(() {
      _isMultiTermSelecting = true;
    });
  }

  Future<void> _handleMultiTermSelectionComplete(
    List<TextItem> selectedItems,
  ) async {
    if (mounted) {
      setState(() {
        _isMultiTermSelecting = false;
      });
    }

    if (selectedItems.isEmpty) return;

    if (selectedItems.length == 1) {
      _handleLongPress(selectedItems.first);
      return;
    }

    final langId = selectedItems.first.langId;
    if (langId == null) return;

    final termText = selectedItems.map((item) => item.text).join().trim();
    if (termText.isEmpty) return;

    final termForm = await ref
        .read(readerProvider.notifier)
        .fetchTermForm(langId, termText);
    if (termForm != null && mounted) {
      _showTermForm(termForm, sentence: _extractSentence(selectedItems.first));
    }
  }

  void _handleTripleTap(TextItem item) async {
    TermTooltipClass.close();

    // Only handle triple tap for terms from the server (items with wordId)
    if (item.wordId == null) return;
    if (item.langId == null) return;

    // Check if triple-tap to mark as known is enabled in settings
    final settings = ref.read(settingsProvider);
    if (!settings.enableTripleTapToMarkKnown) return;

    final wordId = item.wordId!;

    // '99' is the whole edit, so there is nothing to fetch first -- the outbox
    // replays it later, fetching the form itself if it still needs one.  That
    // removes two round trips from a gesture the reader expects to be instant,
    // and makes it work with no signal at all.
    await ref.read(readerProvider.notifier).updateTermStatus(wordId, '99');
    await ref
        .read(outboxProvider.notifier)
        .enqueueTermStatus(wordId, '99', langId: item.langId);

    // Trigger the glow effect to provide visual feedback
    _originalTextItem = item;
    _triggerWordGlow();

    // Show a snackbar to confirm the action
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${item.text}" marked as known'),
          duration: const Duration(milliseconds: 1000),
        ),
      );
    }
  }

  String _extractSentence(TextItem item) {
    final state = ref.read(readerProvider);
    if (state.pageData == null) return '';

    for (final paragraph in state.pageData!.paragraphs) {
      final sentenceItems = <TextItem>[];
      for (final textItem in paragraph.textItems) {
        if (textItem.sentenceId == item.sentenceId) {
          sentenceItems.add(textItem);
        } else if (sentenceItems.isNotEmpty) {
          break;
        }
      }
      if (sentenceItems.isNotEmpty) {
        return sentenceItems.map((i) => i.text).join();
      }
    }
    return '';
  }

  void _showTermForm(
    TermForm termForm, {
    String? sentence,
    String? initialReaderStatus,
  }) {
    _currentTermForm = termForm;
    bool _shouldAutoSaveOnClose = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Keep sheet backgrounds transparent so child widgets render card styling.
      backgroundColor: const Color(0x00000000),
      transitionAnimationController: AnimationController(
        duration: const Duration(milliseconds: 100),
        vsync: Navigator.of(context),
      ),
      builder: (context) {
        final repository = ref.read(readerRepositoryProvider);
        final settings = ref.read(termFormSettingsProvider);
        return AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: PopScope(
            canPop: true,
            onPopInvoked: (didPop) async {
              if (didPop && settings.autoSave && _shouldAutoSaveOnClose) {
                final updatedForm = _currentTermForm ?? termForm;
                ref.read(readerProvider.notifier).saveTerm(updatedForm).then((
                  success,
                ) {
                  if (success && mounted && updatedForm.termId == null) {
                    reloadPage(forceFresh: true);
                  } else if (!success && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to save term')),
                    );
                  }
                });
              }
            },
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return GestureDetector(
                  onVerticalDragEnd: (details) {
                    if (details.primaryVelocity != null &&
                        details.primaryVelocity! > 500) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: TermFormWidget(
                    termForm: _currentTermForm ?? termForm,
                    sentence: sentence,
                    initialReaderStatus: initialReaderStatus,
                    contentService: repository.contentService,
                    dictionaryService: DictionaryService(
                      fetchLanguageSettingsHtml: (langId) => repository
                          .contentService
                          .getLanguageSettingsHtml(langId),
                    ),
                    onUpdate: (updatedForm) {
                      setState(() {
                        _currentTermForm = updatedForm;
                      });
                      setModalState(() {});
                    },
                    onSave: (updatedForm) async {
                      final success = await ref
                          .read(readerProvider.notifier)
                          .saveTerm(updatedForm);
                      if (success && mounted) {
                        if (updatedForm.termId != null) {
                          ref
                              .read(readerProvider.notifier)
                              .updateTermStatus(
                                updatedForm.termId!,
                                updatedForm.status,
                              );
                        } else {
                          await reloadPage(forceFresh: true);
                        }
                        Navigator.of(context).pop();
                      } else {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Failed to save term'),
                            ),
                          );
                        }
                      }
                    },
                    onCancel: () {
                      _shouldAutoSaveOnClose = false;
                      Navigator.of(context).pop();
                    },
                    onDictionaryToggle: (isOpen) {
                      setModalState(() {});
                    },
                    onParentDoubleTap: (parent) async {
                      if (parent.id != null) {
                        final parentTermForm = await ref
                            .read(readerProvider.notifier)
                            .fetchTermFormById(parent.id!);
                        if (parentTermForm != null && mounted) {
                          _showParentTermForm(
                            parentTermForm,
                            sentence: sentence,
                            onParentUpdated: (updatedParent) {
                              setState(() {
                                _currentTermForm = _currentTermForm?.copyWith(
                                  parents: (_currentTermForm?.parents ?? [])
                                      .map(
                                        (existingParent) =>
                                            existingParent.id ==
                                                updatedParent.id
                                            ? updatedParent
                                            : existingParent,
                                      )
                                      .toList(),
                                );
                              });
                            },
                          );
                        }
                      }
                    },
                    onStatus99Changed: (langId) async {
                      if (ref.read(settingsProvider).showStatsBar) {
                        await ref
                            .read(termsProvider.notifier)
                            .loadStats(langId);
                      }
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        _triggerWordGlow();
      }
    });
  }

  void _showParentTermForm(
    TermForm termForm, {
    String? sentence,
    void Function(TermParent)? onParentUpdated,
  }) {
    bool _shouldAutoSaveOnClose = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0x00000000),
      transitionAnimationController: AnimationController(
        duration: const Duration(milliseconds: 100),
        vsync: Navigator.of(context),
      ),
      builder: (context) {
        final repository = ref.read(readerRepositoryProvider);
        final settings = ref.read(termFormSettingsProvider);
        return AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: PopScope(
            canPop: true,
            onPopInvoked: (didPop) async {
              if (didPop && settings.autoSave && _shouldAutoSaveOnClose) {
                final updatedForm = termForm;
                ref.read(readerProvider.notifier).saveTerm(updatedForm).then((
                  success,
                ) {
                  if (success && mounted && updatedForm.termId != null) {
                    ref
                        .read(readerProvider.notifier)
                        .updateTermStatus(
                          updatedForm.termId!,
                          updatedForm.status,
                        );
                  }
                });
              }
            },
            child: StatefulBuilder(
              builder: (context, setModalState) {
                var currentForm = termForm;

                return GestureDetector(
                  onVerticalDragEnd: (details) {
                    if (details.primaryVelocity != null &&
                        details.primaryVelocity! > 500) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: TermFormWidget(
                    termForm: currentForm,
                    sentence: sentence,
                    initialReaderStatus: null,
                    contentService: repository.contentService,
                    dictionaryService: DictionaryService(
                      fetchLanguageSettingsHtml: (langId) => repository
                          .contentService
                          .getLanguageSettingsHtml(langId),
                    ),
                    onUpdate: (updatedForm) {
                      currentForm = updatedForm;
                      setModalState(() {});
                    },
                    onSave: (updatedForm) async {
                      final success = await ref
                          .read(readerProvider.notifier)
                          .saveTerm(updatedForm);
                      if (success && mounted) {
                        onParentUpdated?.call(
                          TermParent(
                            id: updatedForm.termId,
                            term: updatedForm.term,
                            translation: updatedForm.translation,
                            status: int.tryParse(updatedForm.status),
                            syncStatus: updatedForm.syncStatus,
                          ),
                        );
                        Navigator.of(context).pop();
                      } else {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Failed to save term'),
                            ),
                          );
                        }
                      }
                    },
                    onCancel: () {
                      _shouldAutoSaveOnClose = false;
                      Navigator.of(context).pop();
                    },
                    onDictionaryToggle: (isOpen) {
                      setModalState(() {});
                    },
                    onParentDoubleTap: (parent) async {
                      if (parent.id != null) {
                        final parentTermForm = await ref
                            .read(readerProvider.notifier)
                            .fetchTermFormById(parent.id!);
                        if (parentTermForm != null && mounted) {
                          _showParentTermForm(
                            parentTermForm,
                            sentence: sentence,
                            onParentUpdated: (updatedParent) {
                              currentForm = currentForm.copyWith(
                                parents: currentForm.parents
                                    .map(
                                      (existingParent) =>
                                          existingParent.id == updatedParent.id
                                          ? updatedParent
                                          : existingParent,
                                    )
                                    .toList(),
                              );
                              setModalState(() {});
                            },
                          );
                        }
                      }
                    },
                    onStatus99Changed: (langId) async {
                      if (ref.read(settingsProvider).showStatsBar) {
                        await ref
                            .read(termsProvider.notifier)
                            .loadStats(langId);
                      }
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        _triggerWordGlow();
      }
    });
  }

  /// Sentence translation sheet.  Reached from the word card's Sentence button
  /// (see _translateSentenceFromCard).
  void _showSentenceTranslation(String sentence, int languageId) {
    final repository = ref.read(readerRepositoryProvider);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0x00000000),
      transitionAnimationController: AnimationController(
        duration: const Duration(milliseconds: 100),
        vsync: Navigator.of(context),
      ),
      builder: (context) {
        return SentenceTranslationWidget(
          sentence: sentence,
          translation: null,
          languageId: languageId,
          dictionaryService: DictionaryService(
            fetchLanguageSettingsHtml: (langId) =>
                repository.contentService.getLanguageSettingsHtml(langId),
          ),
          onClose: () => Navigator.of(context).pop(),
        );
      },
    );
  }

  Future<void> _goToPage(int pageNum) async {
    final pageData = ref.read(readerProvider).pageData;
    if (pageData == null) return;

    // Log page change for debugging
    ApiLogger.logRequest(
      'ReaderScreen._goToPage',
      details:
          'from=${pageData!.currentPage}, to=$pageNum, bookId=${pageData!.bookId}',
    );

    setState(() {
      _isNavigatingForward = pageNum > pageData!.currentPage;
      _pageKey = ValueKey('${pageData!.bookId}-$pageNum');
      _isLastPageMarkedDone = false;
      _lastAttemptedBookId = pageData!.bookId;
      _lastAttemptedPageNum = pageNum;
      _highlightedWordId = null;
    });

    if (pageNum > pageData!.currentPage) {
      try {
        await ref
            .read(readerProvider.notifier)
            .markPageRead(pageData!.bookId, pageData!.currentPage);
      } catch (e) {
        ApiLogger.logError('markPageRead', e);
      }
    }

    await ref
        .read(readerProvider.notifier)
        .loadPage(
          bookId: pageData!.bookId,
          pageNum: pageNum,
          showFullPageError: false,
          useCache: true,
        );

    ref.read(statsProvider.notifier).loadStats();
  }

  Future<void> _loadPageWithoutMarkingRead(int pageNum) async {
    final pageData = ref.read(readerProvider).pageData;
    if (pageData == null) return;

    // Log page change for debugging
    ApiLogger.logRequest(
      'ReaderScreen._loadPageWithoutMarkingRead',
      details:
          'pageNum=$pageNum, currentPage=${pageData!.currentPage}, bookId=${pageData!.bookId}',
    );

    setState(() {
      _isNavigatingForward = pageNum > pageData!.currentPage;
      _pageKey = ValueKey('${pageData!.bookId}-$pageNum');
      _isLastPageMarkedDone = false;
      _lastAttemptedBookId = pageData!.bookId;
      _lastAttemptedPageNum = pageNum;
      _highlightedWordId = null;
    });

    await ref
        .read(readerProvider.notifier)
        .loadPage(
          bookId: pageData!.bookId,
          pageNum: pageNum,
          showFullPageError: false,
          useCache: true,
        );

    ref.read(statsProvider.notifier).loadStats();
  }

  Future<void> _markPageKnown() async {
    final pageData = ref.read(readerProvider).pageData;
    if (pageData == null) return;

    try {
      await ref
          .read(readerProvider.notifier)
          .markPageKnown(pageData!.bookId, pageData!.currentPage);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Page marked as All Known'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      if (pageData!.currentPage < pageData.pageCount) {
        _goToPage(pageData!.currentPage + 1);
      } else {
        ref
            .read(readerProvider.notifier)
            .loadPage(
              bookId: pageData!.bookId,
              pageNum: pageData!.currentPage,
              showFullPageError: false,
            );
      }
    } catch (e) {
      ApiLogger.logError('markPageAsKnown', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark page as known: $e'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _markLastPageDone(PageData pageData) async {
    try {
      await ref
          .read(readerProvider.notifier)
          .markPageRead(pageData!.bookId, pageData!.currentPage);

      if (mounted) {
        setState(() {
          _isLastPageMarkedDone = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Page marked as done'),
            duration: Duration(seconds: 1),
          ),
        );

        final currentBookState = ref.read(currentBookProvider);
        if (currentBookState.book != null) {
          final updatedBook = currentBookState.book!.copyWith(
            isCompleted: true,
          );
          ref.read(currentBookProvider.notifier).setBook(updatedBook);

          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) =>
                  BookCompletionCelebrationDialog(book: updatedBook),
            );
          }
        }
      }
      ref.read(statsProvider.notifier).loadStats();
    } catch (e) {
      ApiLogger.logError('markPageAsDone', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark page as done: $e'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showPageNavigationSlider() {
    final pageData = ref.read(readerProvider).pageData;
    if (pageData == null) return;

    double tempPage = pageData!.currentPage.toDouble();

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Go to Page'),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Page ${tempPage.toInt()} of ${pageData.pageCount}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  Slider(
                    value: tempPage,
                    min: 1,
                    max: pageData.pageCount.toDouble(),
                    divisions: pageData.pageCount - 1,
                    label: tempPage.toInt().toString(),
                    onChanged: (value) {
                      setDialogState(() {
                        tempPage = value;
                      });
                    },
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _loadPageWithoutMarkingRead(tempPage.toInt());
              },
              child: const Text('Go'),
            ),
          ],
        );
      },
    );
  }
}

/// 延迟显示的进度圈。
///
/// 阅读屏在 App 启动时就要恢复上次在读的书和页码，正文通常直接从本地页
/// 缓存读出，只花一两帧。立刻画进度圈会让每次冷启动都闪一下 loading，
/// 所以先留白，只有在真的慢（超过 [_delay]）时才把进度圈显示出来。
///
/// 留白而不是 [SizedBox.shrink]：占住正文区，避免除背景色外还出现跳变。
class _DeferredLoadingIndicator extends StatefulWidget {
  final String? message;

  const _DeferredLoadingIndicator({this.message});

  /// 留白时长。够长到让本地缓存命中（通常 < 50ms）永远不显示进度圈，
  /// 又够短到网络真的慢时不会让用户对着一片空白发呆。
  static const Duration _delay = Duration(milliseconds: 250);

  @override
  State<_DeferredLoadingIndicator> createState() =>
      _DeferredLoadingIndicatorState();
}

class _DeferredLoadingIndicatorState extends State<_DeferredLoadingIndicator> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_DeferredLoadingIndicator._delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.expand();
    return LoadingIndicator(message: widget.message);
  }
}
