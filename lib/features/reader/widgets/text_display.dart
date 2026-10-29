import 'dart:async';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../../../core/logger/widget_logger.dart';
import '../models/text_item.dart';
import '../models/paragraph.dart';
import '../utils/text_direction_utils.dart';
import '../../../shared/theme/eink.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'term_tooltip.dart';

class TextDisplay extends StatefulWidget {
  final List<Paragraph> paragraphs;
  final void Function(TextItem, BuildContext)? onTap;
  final void Function(TextItem)? onDoubleTap;
  final void Function(TextItem)? onLongPress;
  final VoidCallback? onMultiTermSelectionStart;
  final void Function(List<TextItem>)? onMultiTermSelectionComplete;

  /// 多选被取消（长按/拖动被系统打断）。外层据此复位"正在多选"的标记 ——
  /// 不复位的话翻页手势与点击都会被它一直挡住，整页看起来像卡死。
  final VoidCallback? onMultiTermSelectionCancel;
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

  /// Whether the page is annotated with readings (furigana) -- i.e. whether
  /// every word cell reserves a slot above it for one.
  ///
  /// Deliberately independent of whether the readings have arrived yet: the
  /// slot is reserved as soon as this is true, so the text does not reflow
  /// when they land.  (The web reader adds its `furigana-on` class early for
  /// exactly the same reason.)
  final bool furiganaEnabled;

  /// Readings to paint above the words, keyed by [TextItem.renderKey].
  ///
  /// A word with no entry keeps its (empty, equally tall) slot.
  final Map<String, String> furiganaReadings;

  const TextDisplay({
    super.key,
    required this.paragraphs,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onMultiTermSelectionStart,
    this.onMultiTermSelectionComplete,
    this.onMultiTermSelectionCancel,
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
    this.furiganaEnabled = false,
    this.furiganaReadings = const {},
  });

  /// One tappable word.  [displayOverride] replaces only the rendered
  /// string (manga's vertical columns render one character per tap cell);
  /// taps still report the full [item], so lookups keep the whole word.
  /// [slabTextColor] is the ink for words sitting bare on an opaque light
  /// backdrop the caller paints behind the whole block (the manga view's
  /// always-white reveal slab); without it those words keep their theme
  /// colors, which a dark theme tunes for a dark page.
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
    VoidCallback? onLongPressCancel,
    void Function(TextItem)? onTripleTap,
    bool enableTripleTap = false,
    int doubleTapTimeout = 300,
    int? highlightedWordId,
    int? highlightedParagraphId,
    int? highlightedOrder,
    Set<int> highlightedSentenceIds = const {},
    bool isSelected = false,
    String? displayOverride,
    Color? slabTextColor,
    String? reading,
    bool reserveReadingSlot = false,
  }) {
    Color? textColor;
    Color? backgroundColor;
    bool statusBold = false;

    if (item.wordId != null) {
      final statusMatch = RegExp(r'status(\d+)').firstMatch(item.statusClass);
      final status = statusMatch?.group(1) ?? '0';

      textColor = context.getStatusTextColor(status);
      backgroundColor = context.getStatusBackgroundColor(status);

      // 墨水屏（Kaleido 3 浅彩方案，2026-10-30 起）：状态词块用浅彩底 +
      // 同色系深字双编码（对齐服务器 Boox_Leaf5C.css），未学 0/1 加粗。
      // 旧版是 4 档灰底 + 文字回落正文色（见 eink.dart 顶部注释的来龙去脉）。
      if (context.eInk) {
        backgroundColor = einkStatusBackground(context, status);
        textColor = einkStatusText(context, status);
        statusBold = einkStatusBold(status);
      }
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

    // 墨水屏下两种外发光都去掉：模糊在 16 灰阶下只会渲染成一团脏灰，而且
    // 发光范围比词本身大，等于把每次重绘的面积也放大了。标记改用下边框。
    final eInk = context.eInk;

    final glowEffect = isHighlighted && !eInk
        ? BoxShadow(
            color: context.wordGlowColor,
            blurRadius: 12,
            spreadRadius: 3,
            offset: const Offset(0, 0),
          )
        : null;

    final selectionGlow = isSelected && !eInk
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
          // 漫画揭示框的底板永远是不透明白（mokuro 纸面），深色主题的浅色
          // 文字落上去等于隐身：凡是自己没有色块垫底的词（status-text、
          // 98/99、无 wordId 的纯文本）一律用调用方给的"纸面墨色"。
          // 带色块的词保持主题配对（色块本身不透明，配字对比度有保证），
          // 正在朗读/选中的块同理——文字对的是自己的块，不是底板。
          : (slabTextColor != null && backgroundColor == null
                ? slabTextColor
                : textColor ?? Theme.of(context).textTheme.bodyLarge?.color),
      fontWeight: statusBold ? FontWeight.w700 : fontWeight,
      fontSize: textSize,
      height: lineSpacing,
      fontFamily: fontFamily,
      fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
    );

    // 行盒高度并不总等于 fontSize*height:同一行里汉字与假名若落到不同的回退
    // 字体,行高会取两者的 max(ascent)+max(descent),比纯汉字/纯假名那一行高
    // (实测手机上 25.0 vs 23.0 逻辑 px)。而正文是**每个词各自成块**、在 Wrap
    // 里按顶对齐排的(默认 WrapCrossAlignment.start),列高一不同,词的基线就
    // 互相错开 —— 看起来就是「汉字和假名不平齐」,汉字+假名混排的词最明显。
    // 强制 strut 把每个词的行盒都钉死在 fontSize*height,词与词基线自然对齐。
    final strutStyle = StrutStyle.fromTextStyle(
      textStyle,
      forceStrutHeight: true,
    );

    final wordText = Text(
      displayOverride ?? item.displayText,
      style: textStyle,
      strutStyle: strutStyle,
    );

    // Furigana (readings above the word).  The reading goes in a fixed-height
    // slot *above* the word, and -- crucially -- **every** cell gets that
    // slot, not just the annotated ones.  That is what keeps all the cells in
    // a paragraph the same height: the paragraph is a `Wrap` whose children
    // are laid out independently, so without a uniform slot an annotated cell
    // would be taller than its neighbours and the kanji/kana baselines the
    // strut above works so hard to align would drift apart again.  It is also
    // why the readings can land late without the page reflowing -- the space
    // is already reserved.
    //
    // Sizes scale with [textSize] rather than being the shadowing panel's
    // hardcoded 13/10 (those are tuned for its fixed 19px text).  The 0.5
    // factor matches the web reader's `rt { font-size: 0.5em }`.
    //
    // The slot is scaled by the platform's text scale factor as well, because
    // the word and the reading are: a `SizedBox` is measured in logical pixels
    // and so is *not* touched by text scaling, while the text inside it is.
    // Without this the two drift apart as the system font size grows, and past
    // a scale of ~1.4 the reading is taller than its slot and spills onto the
    // word below.  (Measured on the Leaf5C: its system font scale is 0.85, so
    // an unscaled slot is 25% too tall there -- harmless, but only by luck of
    // which side of 1.0 the device sits on.)
    final readingSlotHeight = MediaQuery.textScalerOf(
      context,
    ).scale(textSize * 0.7);
    final Widget cell = reserveReadingSlot
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: readingSlotHeight,
                child: reading == null
                    ? null
                    : Text(
                        reading,
                        maxLines: 1,
                        style: TextStyle(
                          // A slightly muted copy of the word's own ink: it
                          // stays legible on the status colour blocks, on the
                          // playing-line block, and on an e-ink panel's 16
                          // greys.  (The web reader likewise paints `rt` in
                          // the plain font colour, not the term's status.)
                          color: (textStyle.color ?? Colors.black).withValues(
                            alpha: 0.75,
                          ),
                          fontSize: textSize * 0.5,
                          height: 1.0,
                        ),
                      ),
              ),
              wordText,
            ],
          )
        : wordText;

    final textWidget = Container(
      padding: backgroundColor != null || isSelected
          ? const EdgeInsets.symmetric(horizontal: 2.0)
          : null,
      decoration: BoxDecoration(
        color: blockColor,
        borderRadius: blockRadius,
        // 墨水屏下用一道下边框代替外发光标出"正在读的这句"。
        border: isSelected
            ? Border.all(color: selectionTextColor.withValues(alpha: 0.35))
            : (eInk && isHighlighted)
            ? Border(
                bottom: BorderSide(color: context.playingLineText, width: 2),
              )
            : null,
        boxShadow: [
          ...?selectionGlow == null ? null : [selectionGlow],
          ...?glowEffect == null ? null : [glowEffect],
        ],
      ),
      child: cell,
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
            // 长按/拖动被系统取消（另一个手势赢、路由变化、窗口失焦…）时
            // 不会有 onLongPressEnd，选词状态必须在这里收尾 —— 见
            // _TextDisplayState._handleSelectionCancel。
            onLongPressCancel: onLongPressCancel,
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
      // 残留的多选起点。长按/拖动被系统取消时 onLongPressEnd 不会来，起点
      // 留在字段里会把**之后所有点击**都吞掉（`return` 在这里），外层
      // `_isMultiTermSelecting` 也没人复位 → 翻页与点词全部失效，整页看
      // 起来就是卡死。这里先收尾，再按一次正常点击处理。
      _handleSelectionCancel();
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

  @override
  void didUpdateWidget(TextDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Readings landing (or the furigana setting flipping) changes how tall
    // every word cell is.  A long-press drag caches each cell's screen rect
    // and only rebuilds it at the start of the next drag, so a stale cache
    // would hit-test against the old heights mid-drag.
    if (oldWidget.furiganaEnabled != widget.furiganaEnabled ||
        !identical(oldWidget.furiganaReadings, widget.furiganaReadings)) {
      _clearHitTestCache();
    }
  }

  String _itemKeyId(TextItem item) => item.renderKey;

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
    // 起点没了（取消过一次）却还收到 end：只做收尾，不弹词卡。
    if (start == null) {
      _handleSelectionCancel();
      return;
    }

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

  /// 收尾一次（可能被取消的）选词：清本地选中态，并让外层复位"正在多选"。
  ///
  /// 这是长按手势**没有正常结束**时唯一的出口 —— 手势被取消、被别的手势
  /// 抢走、或者路由变化都会走到这里。
  void _handleSelectionCancel() {
    _clearHitTestCache();
    final wasSelecting =
        _selectionStartItem != null || _selectionCurrentItem != null;
    if (_selectionStartItem != null || _selectionCurrentItem != null) {
      setState(() {
        _selectionStartItem = null;
        _selectionCurrentItem = null;
      });
    }
    if (wasSelecting) {
      widget.onMultiTermSelectionCancel?.call();
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
      onLongPressCancel: _handleSelectionCancel,
      onTripleTap: (item) => widget.onTripleTap?.call(item),
      highlightedWordId: widget.highlightedWordId,
      highlightedParagraphId: widget.highlightedParagraphId,
      highlightedOrder: widget.highlightedOrder,
      highlightedSentenceIds: widget.highlightedSentenceIds,
      isSelected: _isSelected(item),
      reading: widget.furiganaReadings[item.renderKey],
      reserveReadingSlot: widget.furiganaEnabled,
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

    final viewportBox = Scrollable.maybeOf(
      itemContext,
    )?.context.findRenderObject();
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
        duration: MediaQuery.of(context).disableAnimations || context.eInk
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ),
    );
  }
}
