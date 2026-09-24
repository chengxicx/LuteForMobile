import 'dart:async';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../../../core/logger/widget_logger.dart';
import '../models/text_item.dart';
import '../models/paragraph.dart';
import '../utils/text_direction_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'term_tooltip.dart';

class TextDisplay extends StatefulWidget {
  final List<Paragraph> paragraphs;
  final void Function(TextItem, BuildContext)? onTap;
  final void Function(TextItem)? onDoubleTap;
  final void Function(TextItem)? onLongPress;
  final VoidCallback? onMultiTermSelectionStart;
  final void Function(List<TextItem>)? onMultiTermSelectionComplete;
  final void Function(TextItem)? onTripleTap;
  final bool enableTripleTap;
  final int doubleTapTimeout;
  final double textSize;
  final double lineSpacing;
  final String fontFamily;
  final FontWeight fontWeight;
  final bool isItalic;
  final ScrollController? scrollController;
  final double topPadding;
  final double bottomPadding;
  final Widget? bottomControlWidget;
  final int? highlightedWordId;
  final int? highlightedParagraphId;
  final int? highlightedOrder;

  /// Sentences (by [TextItem.sentenceId]) the player is currently on -- the
  /// TTS player's sentence, or the line of the subtitle cue a media player
  /// (MP3 / YouTube / Bilibili) is playing.  They get a background block,
  /// mirroring the web reader's `lute-playing-line`, so the reader can follow
  /// along in the page instead of only in the player bar.
  ///
  /// A set rather than a single id: one subtitle cue can own several
  /// sentences of the page.
  final Set<int> highlightedSentenceIds;

  final TextDirection? textDirection;

  const TextDisplay({
    super.key,
    required this.paragraphs,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onMultiTermSelectionStart,
    this.onMultiTermSelectionComplete,
    this.onTripleTap,
    this.enableTripleTap = false,
    this.doubleTapTimeout = 300,
    this.textSize = 18.0,
    this.lineSpacing = 1.5,
    this.fontFamily = 'Roboto',
    this.fontWeight = FontWeight.normal,
    this.isItalic = false,
    this.scrollController,
    this.topPadding = 0.0,
    this.bottomPadding = 0.0,
    this.bottomControlWidget,
    this.highlightedWordId,
    this.highlightedParagraphId,
    this.highlightedOrder,
    this.highlightedSentenceIds = const {},
    this.textDirection,
  });

  static Widget buildInteractiveWord(
    BuildContext context,
    TextItem item, {
    required double textSize,
    required double lineSpacing,
    required String fontFamily,
    required FontWeight fontWeight,
    required bool isItalic,
    required Key widgetKey,
    void Function(TextItem, BuildContext)? onTap,
    void Function(TextItem)? onDoubleTap,
    void Function(TextItem)? onLongPress,
    void Function(TextItem)? onLongPressStart,
    void Function(TextItem, Offset)? onLongPressMoveUpdate,
    void Function(TextItem)? onLongPressEnd,
    void Function(TextItem)? onTripleTap,
    bool enableTripleTap = false,
    int doubleTapTimeout = 300,
    int? highlightedWordId,
    int? highlightedParagraphId,
    int? highlightedOrder,
    Set<int> highlightedSentenceIds = const {},
    bool isSelected = false,
  }) {
    Color? textColor;
    Color? backgroundColor;

    if (item.wordId != null) {
      final statusMatch = RegExp(r'status(\d+)').firstMatch(item.statusClass);
      final status = statusMatch?.group(1) ?? '0';

      textColor = context.getStatusTextColor(status);
      backgroundColor = context.getStatusBackgroundColor(status);
    }

    final isReadingSentence = highlightedSentenceIds.contains(item.sentenceId);

    final isHighlighted =
        highlightedWordId != null &&
        highlightedWordId == item.wordId &&
        highlightedParagraphId == item.paragraphId &&
        highlightedOrder == item.order;

    final selectionColor = context.multiTermSelectionColor;
    final selectionTextColor = selectionColor.computeLuminance() > 0.5
        ? const Color(0xFF1C1B1F)
        : const Color(0xFFFFFFFF);

    final glowEffect = isHighlighted
        ? BoxShadow(
            color: context.wordGlowColor,
            blurRadius: 12,
            spreadRadius: 3,
            offset: const Offset(0, 0),
          )
        : null;

    final selectionGlow = isSelected
        ? BoxShadow(
            color: selectionColor.withValues(alpha: 0.6),
            blurRadius: 12,
            spreadRadius: 2,
            offset: const Offset(0, 0),
          )
        : null;

    // The playing line's block replaces a word's own status colour while it
    // is on: the block has to read as one mark, and a status patch inside it
    // would break it up.  Its padding is kept, though -- padding is *inside*
    // the block, so it widens the mark rather than notching it, and keeping
    // it means the highlight moving down the page does not reflow the text.
    final blockColor = isSelected
        ? selectionColor
        : isReadingSentence
        ? context.playingLineHighlight
        : backgroundColor;

    // Square corners while the line is being read: every word is its own box,
    // so a radius on each one would notch the junctions between them.  The
    // padding rule is deliberately tied to the *status* background only --
    // adding it for the playing block would shift every word 2px when the
    // highlight moves on.
    final blockRadius = isReadingSentence
        ? BorderRadius.zero
        : BorderRadius.circular(4);

    final textStyle = TextStyle(
      color: isSelected
          ? selectionTextColor
          : isReadingSentence
          ? context.playingLineText
          : textColor ?? Theme.of(context).textTheme.bodyLarge?.color,
      fontWeight: fontWeight,
      fontSize: textSize,
      height: lineSpacing,
      fontFamily: fontFamily,
      fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
    );

    final textWidget = Container(
      padding: backgroundColor != null || isSelected
          ? const EdgeInsets.symmetric(horizontal: 2.0)
          : null,
      decoration: BoxDecoration(
        color: blockColor,
        borderRadius: blockRadius,
        border: isSelected
            ? Border.all(color: selectionTextColor.withValues(alpha: 0.35))
            : null,
        boxShadow: [
          ...?selectionGlow == null ? null : [selectionGlow],
          ...?glowEffect == null ? null : [glowEffect],
        ],
      ),
      child: Text(item.text, style: textStyle),
    );

    if (item.wordId != null) {
      return RepaintBoundary(
        key: widgetKey,
        child: Builder(
          builder: (context) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap?.call(item, context),
            onLongPress: onLongPressStart == null && onLongPress != null
                ? () => onLongPress(item)
                : null,
            onLongPressStart: onLongPressStart != null
                ? (_) => onLongPressStart(item)
                : null,
            onLongPressMoveUpdate: onLongPressMoveUpdate != null
                ? (details) =>
                      onLongPressMoveUpdate(item, details.globalPosition)
                : null,
            onLongPressEnd: onLongPressEnd != null
                ? (_) => onLongPressEnd(item)
                : null,
            child: textWidget,
          ),
        ),
      );
    }

    return RepaintBoundary(key: widgetKey, child: textWidget);
  }

  @override
  State<TextDisplay> createState() => _TextDisplayState();
}

class _TextDisplayState extends State<TextDisplay> {
  Timer? _singleTapTimer;
  Timer? _tripleTapTimer;
  TextItem? _lastTappedItem;
  TextItem? _selectionStartItem;
  TextItem? _selectionCurrentItem;
  final Map<String, GlobalKey> _itemKeys = {};
  int _buildCount = 0;

  /// 长按选词期间的命中测试缓存：item 与屏幕矩形一一对应。
  /// 拖动时每次指针移动都要做命中测试；若每次都遍历全页并调用
  /// findRenderObject / localToGlobal（都是相对昂贵的操作），
  /// 长页面（数百个词）上会明显掉帧。因此在长按开始时算一次，
  /// 拖动期间只做纯矩形包含判断。
  List<TextItem>? _hitTestItems;
  List<Rect>? _hitTestRects;

  /// 上一帧正在朗读/播放的句子集合，用来只在「播到的行变了」时触发一次
  /// 自动滚动 —— 播放状态本身每 250ms 就会重建，不能跟着滚。
  Set<int> _lastPlayingSentenceIds = const {};

  bool _autoScrollScheduled = false;

  void _buildHitTestCache() {
    final items = _allItems();
    final kept = <TextItem>[];
    final rects = <Rect>[];
    for (final item in items) {
      final context = _itemKeys[_itemKeyId(item)]?.currentContext;
      final renderObject = context?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      kept.add(item);
      rects.add(renderObject.localToGlobal(Offset.zero) & renderObject.size);
    }
    _hitTestItems = kept;
    _hitTestRects = rects;
  }

  void _clearHitTestCache() {
    _hitTestItems = null;
    _hitTestRects = null;
  }

  @override
  void initState() {
    super.initState();
  }

  void _handleTap(TextItem item, BuildContext context) {
    if (_selectionStartItem != null) {
      return;
    }
    if (_lastTappedItem == item &&
        _tripleTapTimer != null &&
        _tripleTapTimer!.isActive) {
      _singleTapTimer?.cancel();
      _tripleTapTimer?.cancel();
      widget.onTripleTap?.call(item);
      TermTooltipClass.close();
      _tripleTapTimer = null;
      _singleTapTimer = null;
    } else if (_lastTappedItem == item &&
        _singleTapTimer != null &&
        _singleTapTimer!.isActive) {
      _singleTapTimer?.cancel();
      TermTooltipClass.close();

      if (widget.enableTripleTap) {
        _tripleTapTimer = Timer(
          Duration(milliseconds: widget.doubleTapTimeout),
          () {
            _tripleTapTimer = null;
            widget.onDoubleTap?.call(item);
            _singleTapTimer = null;
          },
        );
      } else {
        widget.onDoubleTap?.call(item);
        _singleTapTimer = null;
      }
    } else {
      _tripleTapTimer?.cancel();
      _tripleTapTimer = null;

      _singleTapTimer?.cancel();
      widget.onTap?.call(item, context);

      _singleTapTimer = Timer(
        Duration(milliseconds: widget.doubleTapTimeout),
        () {
          _singleTapTimer = null;
        },
      );
    }
    _lastTappedItem = item;
  }

  @override
  void dispose() {
    _singleTapTimer?.cancel();
    _tripleTapTimer?.cancel();
    super.dispose();
  }

  String _itemKeyId(TextItem item) {
    return '${item.paragraphId}-${item.order}-${item.wordId ?? 'space'}';
  }

  GlobalKey _itemKeyFor(TextItem item) {
    final keyId = _itemKeyId(item);
    return _itemKeys.putIfAbsent(keyId, GlobalKey.new);
  }

  List<TextItem> _allItems() {
    return widget.paragraphs
        .expand((paragraph) => paragraph.textItems)
        .toList();
  }

  List<TextItem> _selectedItems(TextItem start, TextItem end) {
    final startOrder = start.order < end.order ? start.order : end.order;
    final endOrder = start.order > end.order ? start.order : end.order;
    return _allItems()
        .where((item) => item.order >= startOrder && item.order <= endOrder)
        .toList();
  }

  bool _isSelected(TextItem item) {
    final start = _selectionStartItem;
    final current = _selectionCurrentItem;
    if (start == null || current == null) return false;

    final startOrder = start.order < current.order
        ? start.order
        : current.order;
    final endOrder = start.order > current.order ? start.order : current.order;
    return item.order >= startOrder && item.order <= endOrder;
  }

  TextItem? _findItemAtGlobalPosition(Offset globalPosition) {
    // 优先走缓存（长按拖动路径）。
    final cachedItems = _hitTestItems;
    final cachedRects = _hitTestRects;
    if (cachedItems != null && cachedRects != null) {
      for (var i = 0; i < cachedItems.length; i++) {
        if (cachedRects[i].contains(globalPosition)) {
          return cachedItems[i];
        }
      }
      return null;
    }

    // 无缓存时回退到实时计算，保持原有行为。
    for (final item in _allItems()) {
      final itemKey = _itemKeys[_itemKeyId(item)];
      final context = itemKey?.currentContext;
      final renderObject = context?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }

      final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
      if (rect.contains(globalPosition)) {
        return item;
      }
    }

    return null;
  }

  void _handleSelectionStart(TextItem item) {
    TermTooltipClass.close();
    HapticFeedback.mediumImpact();
    // 清掉上一次的缓存，首次移动时会基于新布局重建。
    _clearHitTestCache();
    setState(() {
      _selectionStartItem = item;
      _selectionCurrentItem = item;
    });
    widget.onMultiTermSelectionStart?.call();
  }

  void _handleSelectionMove(TextItem item, Offset globalPosition) {
    if (_selectionStartItem == null) return;
    // 首次移动时建立命中缓存，之后每次移动只做矩形包含判断。
    if (_hitTestItems == null) {
      _buildHitTestCache();
    }
    final hoveredItem = _findItemAtGlobalPosition(globalPosition) ?? item;
    if (_selectionCurrentItem == hoveredItem) return;
    setState(() {
      _selectionCurrentItem = hoveredItem;
    });
  }

  void _handleSelectionEnd(TextItem item) {
    _clearHitTestCache();
    final start = _selectionStartItem;
    final current = _selectionCurrentItem ?? item;
    if (start == null) return;

    final selectedItems = _selectedItems(start, current);
    HapticFeedback.selectionClick();
    setState(() {
      _selectionStartItem = null;
      _selectionCurrentItem = null;
    });

    if (widget.onMultiTermSelectionComplete != null) {
      widget.onMultiTermSelectionComplete!(selectedItems);
      return;
    }

    if (selectedItems.length == 1) {
      widget.onLongPress?.call(selectedItems.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild(
      'TextDisplay',
      _buildCount,
      'paragraphs: ${widget.paragraphs.length}',
    );
    _maybeAutoScrollToPlayingSentence();
    final fallbackDirection =
        widget.textDirection ?? Directionality.of(context);
    return RepaintBoundary(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: EdgeInsets.only(
          top: 16 + widget.topPadding,
          left: 16,
          right: 16,
          bottom: 16 + widget.bottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...widget.paragraphs.map((paragraph) {
              return _buildParagraph(context, paragraph, fallbackDirection);
            }),
            if (widget.bottomControlWidget != null) ...[
              const SizedBox(height: 16),
              widget.bottomControlWidget!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildParagraph(
    BuildContext context,
    Paragraph paragraph,
    TextDirection fallbackDirection,
  ) {
    final textDirection =
        widget.textDirection ??
        TextDirectionUtils.inferFromItems(
          paragraph.textItems,
          fallback: fallbackDirection,
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Directionality(
        textDirection: textDirection,
        child: Align(
          alignment: textDirection == TextDirection.rtl
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Wrap(
            spacing: 0,
            runSpacing: 0,
            textDirection: textDirection,
            children: paragraph.textItems.asMap().entries.map((entry) {
              final item = entry.value;
              return _buildInteractiveWord(context, item);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildInteractiveWord(BuildContext context, TextItem item) {
    return TextDisplay.buildInteractiveWord(
      context,
      item,
      textSize: widget.textSize,
      lineSpacing: widget.lineSpacing,
      fontFamily: widget.fontFamily,
      fontWeight: widget.fontWeight,
      isItalic: widget.isItalic,
      widgetKey: _itemKeyFor(item),
      onTap: (item, context) => _handleTap(item, context),
      onDoubleTap: (item) => widget.onDoubleTap?.call(item),
      onLongPress: (item) => widget.onLongPress?.call(item),
      onLongPressStart: (item) => _handleSelectionStart(item),
      onLongPressMoveUpdate: (item, globalPosition) =>
          _handleSelectionMove(item, globalPosition),
      onLongPressEnd: (item) => _handleSelectionEnd(item),
      onTripleTap: (item) => widget.onTripleTap?.call(item),
      highlightedWordId: widget.highlightedWordId,
      highlightedParagraphId: widget.highlightedParagraphId,
      highlightedOrder: widget.highlightedOrder,
      highlightedSentenceIds: widget.highlightedSentenceIds,
      isSelected: _isSelected(item),
    );
  }

  /// First item of the sentence(s) the player is on, or null when the player
  /// is somewhere else in the book (a media book's page is only a slice of
  /// its cues, so the line being played is often not on this page).
  TextItem? _firstPlayingItem() {
    if (widget.highlightedSentenceIds.isEmpty) return null;
    for (final item in _allItems()) {
      if (widget.highlightedSentenceIds.contains(item.sentenceId)) return item;
    }
    return null;
  }

  /// Follow the playback: when the marked sentence changes, bring it into
  /// view.
  ///
  /// Deliberately a no-op while the mark is already on screen: scrolling then
  /// would move the page under a reader who is following along perfectly well
  /// where they are.  Only the change is interesting, not the player's 250 ms
  /// position ticks, so the comparison is against the previous build's set.
  void _maybeAutoScrollToPlayingSentence() {
    final ids = widget.highlightedSentenceIds;
    if (setEquals(ids, _lastPlayingSentenceIds)) return;
    _lastPlayingSentenceIds = ids;
    if (ids.isEmpty || _autoScrollScheduled) return;

    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted) return;
      _scrollToPlayingSentence();
    });
  }

  void _scrollToPlayingSentence() {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;

    final item = _firstPlayingItem();
    if (item == null) return;

    final itemContext = _itemKeys[_itemKeyId(item)]?.currentContext;
    if (itemContext == null) return;

    final itemBox = itemContext.findRenderObject();
    if (itemBox is! RenderBox || !itemBox.hasSize) return;

    final viewportBox = Scrollable.maybeOf(itemContext)?.context.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return;

    final itemRect = itemBox.localToGlobal(Offset.zero) & itemBox.size;
    final viewportRect =
        viewportBox.localToGlobal(Offset.zero) & viewportBox.size;

    // A tenth of the viewport as margin, so a line just barely peeking in at
    // the edge still counts as out of view.
    final margin = viewportRect.height * 0.1;
    final inView =
        itemRect.top >= viewportRect.top + margin &&
        itemRect.bottom <= viewportRect.bottom - margin;
    if (inView) return;

    unawaited(
      Scrollable.ensureVisible(
        itemContext,
        alignment: 0.35,
        duration: MediaQuery.of(context).disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ),
    );
  }
}
