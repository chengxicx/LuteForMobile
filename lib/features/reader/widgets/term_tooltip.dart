import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/term_tooltip.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../core/network/session_manager.dart';
import '../../settings/providers/settings_provider.dart';

String _formatTranslation(String? translation) {
  if (translation == null) return '';

  final lines = translation.split(RegExp(r'[\n\r]+'));

  final result = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final trimmedLine = lines[i].trim();
    if (trimmedLine.isEmpty) continue;

    if (result.isNotEmpty) {
      result.write(', ');
    }

    result.write(trimmedLine);
  }

  return result.toString();
}

class _AnimatedTermTooltip extends StatefulWidget {
  final TermTooltip termTooltip;
  final VoidCallback onClose;
  final Key? widgetKey;

  /// Read the term aloud.  Null hides the button.
  final VoidCallback? onSpeak;

  /// Show the translation of the sentence the term sits in.  Null hides it.
  final VoidCallback? onSentenceTranslation;

  /// Open the grammar page for the sentence the term sits in.  Null hides
  /// the button.
  final VoidCallback? onGrammar;

  /// False greys the Grammar button out: the page pre-analysis covered this
  /// sentence and matched nothing, so tapping would only reach a guaranteed
  /// empty page.  The card is static once shown, so the state never flips
  /// mid-display (e-ink must not redraw an open card).
  final bool grammarEnabled;

  const _AnimatedTermTooltip({
    required this.termTooltip,
    required this.onClose,
    this.widgetKey,
    this.onSpeak,
    this.onSentenceTranslation,
    this.onGrammar,
    this.grammarEnabled = true,
  });

  @override
  State<_AnimatedTermTooltip> createState() => _AnimatedTermTooltipState();
}

class _AnimatedTermTooltipState extends State<_AnimatedTermTooltip>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    // 缩放用 easeOutBack：轻微过冲，让弹窗「弹」出来而不是匀速放大，
    // 更有生命感。起点从 0.9 收到 0.92、配合 100ms 时长，过冲幅度很小。
    _scaleAnimation = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    // 淡入保持 easeOut，避免与缩放叠加后显得晃。
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = _TooltipContent(
      termTooltip: widget.termTooltip,
      onSpeak: widget.onSpeak,
      onSentenceTranslation: widget.onSentenceTranslation,
      onGrammar: widget.onGrammar,
      grammarEnabled: widget.grammarEnabled,
    );

    // 定位（Positioned）由 OverlayEntry 的 builder 负责，这里只出卡片本体。
    // 以前这里还包了一层 Positioned，测量 entry 会出现外层 -9999 和内层
    // Offset.zero 两层 Positioned 抢同一个 RenderObject 的 parent data，
    // debug 断言直接报「Competing ParentDataWidgets」（release 只是碰巧没炸）。
    // widgetKey 挂在这里：本组件是组合件，findRenderObject 会落到同一卡片盒。
    return GestureDetector(
      key: widget.widgetKey,
      onTap: widget.onClose,
      // 墨水屏：不做淡入/缩放动画 —— 每一帧局部刷新都会留残影，
      // 直接整卡落墨（Leaf 5C 反馈：词卡看不清、闪）。
      child: context.eInk
          ? card
          : FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: card,
              ),
            ),
    );
  }
}

class _TooltipContent extends ConsumerWidget {
  final TermTooltip termTooltip;
  final VoidCallback? onSpeak;
  final VoidCallback? onSentenceTranslation;
  final VoidCallback? onGrammar;
  final bool grammarEnabled;

  const _TooltipContent({
    required this.termTooltip,
    this.onSpeak,
    this.onSentenceTranslation,
    this.onGrammar,
    this.grammarEnabled = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showTooltipImages = ref.watch(
      termFormSettingsProvider.select((settings) => settings.showTooltipImages),
    );
    final eink = context.eInk;

    return Material(
      // 墨水屏不要 elevation：阴影的高斯模糊量化成一圈脏灰残影，
      // 卡片轮廓交给实线描边。
      elevation: eink ? 0 : 8,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: context.appColorScheme.background.surface,
          boxShadow: eink
              ? null
              : [
                  BoxShadow(
                    color: context.appColorScheme.text.primary.withValues(
                      alpha: 0.2,
                    ),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
          border: Border.all(
            color: eink
                ? context.appColorScheme.border.outline
                : context.appColorScheme.border.outline.withValues(alpha: 0.2),
            width: eink ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        // IntrinsicWidth：卡片宽度贴最宽的子项收窄。没有它，按钮行的
        // Center 会把卡片撑到 maxWidth——文字短时整卡 240dp、文字全挤在
        // 左边，右半片空白，看起来左右不对称（2026-10-03 反馈）。
        // 包在 padding 内侧，保证按内容宽 + padding 收，不会把按钮行挤出界。
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showTooltipImages && termTooltip.imageUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      _resolveImageUrl(
                        termTooltip.imageUrl!,
                        ref.read(settingsProvider).serverUrl,
                      ),
                      headers: SessionManager.authHeaders(),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              // 发音入口就是单词旁的喇叭：紧凑文字按钮挤在卡片底部容易误点，
              // 改成无文字图标贴着单词。Flexible 保证长词换行时喇叭不被挤出卡片。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      termTooltip.term,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: eink ? 15 : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onSpeak != null)
                    IconButton(
                      onPressed: onSpeak,
                      tooltip: 'Pronounce',
                      icon: const Icon(Icons.volume_up),
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      color: context.appColorScheme.material3.primary,
                    ),
                ],
              ),
              if (termTooltip.romanization != null) ...[
                const SizedBox(height: 2),
                Text(
                  termTooltip.romanization!,
                  // 读音独立一行（斜体），释义紧随其后；e-ink 同样不用半透明。
                  style: (eink
                          ? Theme.of(context).textTheme.bodySmall
                          : Theme.of(context).textTheme.bodySmall)!
                      .copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: eink ? 1.0 : 0.55),
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (termTooltip.translation != null) ...[
                const SizedBox(height: 4),
                Text(
                  _formatTranslation(termTooltip.translation),
                  // 墨水屏下释义用正文字号 + 全不透明：半透明灰在 e-ink 上
                  // 就是浅灰底浅灰字，是"看不清"的主因。
                  style: (eink
                          ? Theme.of(context).textTheme.bodyMedium
                          : Theme.of(context).textTheme.bodySmall)!
                      .copyWith(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: eink ? 1.0 : 0.85),
                      ),
                  maxLines: eink ? 5 : 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (termTooltip.parents.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...termTooltip.parents.map(
                  (parent) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '(${parent.term})',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 1.0),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (parent.translation != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatTranslation(parent.translation),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: Theme.of(context).colorScheme.onSurface
                                .withValues(alpha: eink ? 1.0 : 0.7),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (onSentenceTranslation != null ||
                  (onGrammar != null && grammarEnabled)) ...[
                const SizedBox(height: 8),
                // 胶囊描边按钮带文字：36dp 高比 44dp 纯图标版小巧，12dp 间距
                // 仍把两个命中区明确隔开。卡片已由 IntrinsicWidth 贴内容收宽，
                // 文字短时按钮行就是内容区全宽（贴 12dp 边距），长文本时经
                // Center 居中。该句没有语法点时（预分析确认零命中）语法按钮
                // 整个不显示，而不是置灰占位。
                //
                // FittedBox(scaleDown)：不同设备的字体度量不同，两个胶囊的
                // 自然总宽可能略超内容区（OnePlus 实测 219 vs 214），min Row
                // 一旦溢出就把 Grammar 的右边距挤没、按钮行左右不对称
                //（2026-10-03 二次反馈）。装得下原样居中，装不下整体等比
                // 缩一点，两端永远对称。
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                        if (onSentenceTranslation != null)
                          _TooltipActionButton(
                            icon: Icons.translate,
                            label: 'Sentence',
                            onPressed: onSentenceTranslation!,
                          ),
                        if (onSentenceTranslation != null &&
                            onGrammar != null &&
                            grammarEnabled)
                          const SizedBox(width: 12),
                        if (onGrammar != null && grammarEnabled)
                          _TooltipActionButton(
                            icon: Icons.spellcheck,
                            label: 'Grammar',
                            onPressed: onGrammar!,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact labelled outlined button for the tooltip card.
///
/// A tap lands here rather than on the card's own close handler: a child
/// recogniser wins the gesture arena, so pressing a button never dismisses
/// the card.
class _TooltipActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _TooltipActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final eink = context.eInk;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: context.appColorScheme.material3.primary,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(
          color: context.appColorScheme.border.outline,
          width: eink ? 1.5 : 1,
        ),
        textStyle: const TextStyle(fontSize: 13),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

String _resolveImageUrl(String imageUrl, String serverUrl) {
  final trimmed = imageUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) {
    return trimmed;
  }

  final normalizedServer = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;
  final normalizedPath = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return '$normalizedServer$normalizedPath';
}

class TermTooltipClass {
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;
  static final GlobalKey _tooltipKey = GlobalKey();
  static bool _isHidden = false;
  static bool _makeVisibleRequested = false;
  static Offset _tooltipPosition = Offset.zero;

  static void show(
    BuildContext context,
    TermTooltip termTooltip,
    Rect termRect, {
    VoidCallback? onSpeak,
    VoidCallback? onSentenceTranslation,
    VoidCallback? onGrammar,
    bool grammarEnabled = true,
  }) {
    close();
    _makeVisibleRequested = false;

    final screenSize = MediaQuery.of(context).size;
    final eink = context.eInk;
    _isHidden = false;

    _currentEntry = OverlayEntry(
      // 测量 entry：丢到屏幕外量尺寸，量完即撤。
      builder: (ctx) => Positioned(
        left: -9999,
        top: -9999,
        child: _AnimatedTermTooltip(
          termTooltip: termTooltip,
          onClose: close,
          widgetKey: _tooltipKey,
          onSpeak: onSpeak,
          onSentenceTranslation: onSentenceTranslation,
          onGrammar: onGrammar,
          grammarEnabled: grammarEnabled,
        ),
      ),
    );

    Overlay.of(context).insert(_currentEntry!);
    debugPrint(
      'Tooltip: measurement entry inserted, term="${termTooltip.term}"',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final renderBox =
          _tooltipKey.currentContext?.findRenderObject() as RenderBox?;
      debugPrint('Tooltip: postFrame renderBox=${renderBox?.size}');
      if (renderBox != null) {
        final tooltipSize = renderBox.size;
        final tooltipWidth = tooltipSize.width;
        final tooltipHeight = tooltipSize.height;

        const verticalOffset = 12.0;
        const horizontalMargin = 8.0;

        double left = termRect.center.dx - tooltipWidth / 2;
        double top = termRect.top - tooltipHeight - verticalOffset;

        if (left < horizontalMargin) {
          left = horizontalMargin;
        } else if (left + tooltipWidth > screenSize.width - horizontalMargin) {
          left = screenSize.width - tooltipWidth - horizontalMargin;
        }

        if (top < 0) {
          top = termRect.bottom + verticalOffset;
        }

        _tooltipPosition = Offset(left, top);

        _currentEntry?.remove();
        _currentEntry = OverlayEntry(
          builder: (ctx) => Positioned(
            left: _tooltipPosition.dx,
            top: _tooltipPosition.dy,
            child: _AnimatedTermTooltip(
              termTooltip: termTooltip,
              onClose: close,
              widgetKey: _tooltipKey,
              onSpeak: onSpeak,
              onSentenceTranslation: onSentenceTranslation,
              onGrammar: onGrammar,
              grammarEnabled: grammarEnabled,
            ),
          ),
        );
        Overlay.of(context).insert(_currentEntry!);

        if (_makeVisibleRequested && _isHidden) {
          makeVisible();
        }
      }
    });
    _setupAutoDismiss(eink: eink);
  }

  static void makeVisible() {
    if (_currentEntry == null) {
      _makeVisibleRequested = true;
      return;
    }
    if (!_isHidden) return;
    _isHidden = false;
    _currentEntry?.markNeedsBuild();
  }

  static void close() {
    _dismissTimer?.cancel();
    // entry 可能已被框架摘掉（Overlay 随路由重建等），此时 entry.mounted 为
    // false 而 remove() 里的 null check 会在 release 包直接抛异常 —— 而且
    // 抛在 `_currentEntry = null` 之前，static 里留着一具尸体，之后每次
    // close()（每次点词的第一行）都重复崩溃，词卡和发音整个瘫痪。
    final entry = _currentEntry;
    _currentEntry = null;
    _isHidden = false;
    _makeVisibleRequested = false;
    if (entry?.mounted == true) {
      entry!.remove();
    }
  }

  static void _setupAutoDismiss({required bool eink}) {
    _dismissTimer?.cancel();
    // 3 秒体感等于"没有卡"：边听 TTS 边点词时，读音还在响、卡片已经没了，
    // 用户看到的就是"有声音但看不到词卡"（OnePlus 复现实录）。统一 10 秒，
    // 点卡片或点正文任意处随时可关。
    _dismissTimer = Timer(const Duration(seconds: 10), () {
      close();
    });
  }
}
