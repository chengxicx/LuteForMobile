import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/dictionary_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../models/chapter_nav.dart';
import '../models/epub_chapter.dart';
import '../models/paragraph.dart';
import '../models/text_item.dart';
import '../services/epub_local_server.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/eink_paper.dart';

/// Reader-mode EPUB chapter, rendered as the server's standalone page
/// (`/read/epub_render/<bookId>/<page>`) in a WebView.
///
/// The page mounts the word spans exactly like the web reader
/// (original book styling, status colours, furigana, fixed-layout fit),
/// so this widget is mostly plumbing between the page's JS bridge
/// (`window.LuteEpubBridge` / `flutter_inappwebview.callHandler`) and
/// the reader's native interactions:
///
///  * word taps (single / double / triple, the same windows the text
///    display uses, decided page-side) open the native term card /
///    status cycle / mark-known flows;
///  * status changes pushed into [paragraphs] are diffed in
///    [didUpdateWidget] and applied in-page via `setStatus`;
///  * the look mode ([look]) and furigana flag follow the app settings;
///  * the scroll offset is persisted per book and restored after load;
///  * fixed-layout chapters get zoom buttons (`setZoom` page-side;
///    reflowing chapters could use them too, but their text flows at a
///    readable size and pinch is a viewport-level gesture we disabled
///    to keep double-tap = status cycle).
class EpubChapterView extends StatefulWidget {
  final int bookId;
  final int pageNum;
  final String serverUrl;
  final EpubChapterData chapter;

  /// The page's tokens as the reader models them (rebuilt from the same
  /// `#lute-epub-tokens` JSON by the HTML parser).  Status updates arrive
  /// as new instances of this list; word-id lookup for taps reads it too.
  final List<Paragraph> paragraphs;

  /// Current look mode: 'original' / 'night' / 'theme'.
  final String look;

  /// Whether furigana should render in-page (the caller resolves this
  /// from the app setting and the page's furigana capability).
  final bool furiganaEnabled;

  /// Triple-tap-to-mark-known.  Page-side it only decides whether the
  /// second tap settles immediately or waits one more window for a
  /// third press; a mid-session change applies on the next chapter.
  final bool enableTripleTap;

  /// Offline-pack server, when the platform supports it (null on web).
  /// When the server is unreachable and the pack has this chapter, the
  /// WebView loads the local copy instead -- the page is the same
  /// document, so every bridge call below works unchanged.
  final EpubLocalServer? localServer;

  /// Fired once the *server's* copy of the chapter finished loading
  /// (i.e. we are online and authenticated) -- the reader uses it to
  /// background-cache this chapter and the next into the offline pack.
  final VoidCallback? onOnlineChapterLoaded;

  /// Refreshes the pack's mutable assets in the background, returning the
  /// fresh theme CSS when the packed copy was stale.
  ///
  /// A WebView loading the pack cannot revalidate it, so without this a
  /// theme change would leave the reader on the previous palette -- dark
  /// chrome around a white sheet.  It used to be *awaited* ahead of the
  /// first navigation, which cost a measured 1.2 s of blank chapter on
  /// every cold open; the open now paints from the on-disk copy and this
  /// runs behind it, the fresh CSS (when there is any) hot-applied onto
  /// the live page.
  final Future<String?> Function()? refreshPackAssets;

  /// Fired on every press that starts inside the chapter, before the page
  /// has decided what it meant.
  ///
  /// The reader uses it to dismiss the word card.  The Flutter-rendered
  /// text path gets that for free -- its `GestureDetector.onTapDown` runs
  /// on any press -- but nothing in Flutter sees a press that lands in the
  /// chapter: the eager gesture recognizer hands the pointer straight to
  /// Chromium, so the reader's own `onTapDown` never fires and a card left
  /// open stayed open until the 10 s timer.
  final VoidCallback? onPress;

  /// Fired when a click lands on anything that is not a word -- the
  /// chapter's own text container, an image, the gaps between lines.
  ///
  /// The reader uses it for the same thing its `GestureDetector.onTap`
  /// does on the Flutter-rendered text: in fullscreen mode, a tap on empty
  /// space brings the chrome back.  Only the page knows which of its
  /// children is a word, so the chapter view wires a capture-phase click
  /// listener into the document and reports the misses.
  final VoidCallback? onBlankTap;

  /// The end-of-chapter block this chapter should carry: the previous /
  /// next chapter it leads to and the contents row, or null for a chapter
  /// that stands alone (a book outside any set) or one whose layout is
  /// fixed (a fixed-layout page has no flow to append to).
  ///
  /// It is *injected* rather than rendered by the server, so the block
  /// also appears on chapters served from an offline pack written before
  /// the feature existed -- the pack stores the page HTML verbatim, and
  /// re-rendering a shelf of books to gain a footer would be absurd.
  final ChapterNavConfig? chapterNav;

  /// Previous (-1) / next (+1) chapter was pressed in that block.
  final ValueChanged<int>? onChapterNav;

  /// The Contents row was pressed.
  final VoidCallback? onOpenContents;

  /// Lets the reader move this chapter from outside the WebView.
  ///
  /// On an e-ink device the page keys are the main way through a book, and
  /// a chapter is one long scrolled document inside a platform view -- the
  /// reader's own scroll controller knows nothing about it, and "one Lute
  /// page per chapter" means the page-turn path does nothing here.
  final EpubChapterScroll? scroll;

  /// The book's language id, used to complete every word this view hands
  /// back to the reader.
  ///
  /// The chapter's token stream (`#lute-epub-tokens`) carries no language:
  /// it is `[text, wo_id, status, sentence, paragraph]`, so every [TextItem]
  /// rebuilt from it has a null `langId` -- and a null `langId` is what
  /// makes the local dictionary lookup answer nothing (`DictRepository`
  /// cannot route to a dictionary file without it) and hides the
  /// sentence-translation button on the word card.  One book is one
  /// language, so the book's own id is the right answer for every word in
  /// the chapter, and this is the one place where words leave the page.
  final int? languageId;

  /// Reading text size, in the same logical pixels the Flutter-rendered
  /// text uses.  A chapter brings its own typography inside the WebView,
  /// so the reading pane's size control has to be pushed into the page
  /// (which is what its own A+/A- buttons do, by stamping the chapter
  /// container); without this the control silently did nothing on an
  /// EPUB chapter while working on a text page.
  final double textSize;

  /// Fired for a settled word tap.  The second argument is the *screen*
  /// rect the word card should hang off: only Chromium knows where the
  /// word sits inside the page (it is a `<span>` in a scrolled, zoomed
  /// viewport), so the reader cannot derive it from the widget tree the
  /// way it does for the Flutter-rendered text.
  final void Function(TextItem item, Rect anchor) onTap;
  final void Function(TextItem item) onDoubleTap;
  final void Function(TextItem item)? onTripleTap;

  /// Fired for a long press on a word -- the gesture that opens the term
  /// edit form on the Flutter-rendered text.
  ///
  /// The page settles *clicks* (single / double / triple) but knows
  /// nothing about a press that never turns into one, so this is wired
  /// from the app side (see [_longPressScript]) the same way
  /// [onBlankTap] is: a chapter rendered before the wiring existed -- every
  /// chapter in an offline pack written earlier -- still gets it, without
  /// re-rendering the book.
  final void Function(TextItem item, Rect anchor)? onLongPress;

  /// A long press that is *held* and then dragged is a multi-word
  /// selection on the Flutter-rendered text, and it is one here too --
  /// measured in the page by [_longPressScript], which is the only place
  /// the finger's position is observable.  These three mirror the
  /// callbacks [TextDisplay] hands its parent: the range is painted while
  /// the finger moves and reported once, on release.
  final VoidCallback? onMultiTermSelectionStart;
  final void Function(List<TextItem> items, Rect anchor)?
      onMultiTermSelectionComplete;
  final VoidCallback? onMultiTermSelectionCancel;

  const EpubChapterView({
    super.key,
    required this.bookId,
    required this.pageNum,
    required this.serverUrl,
    required this.chapter,
    required this.paragraphs,
    required this.look,
    required this.furiganaEnabled,
    required this.enableTripleTap,
    this.localServer,
    this.onOnlineChapterLoaded,
    this.refreshPackAssets,
    this.onPress,
    this.onBlankTap,
    this.chapterNav,
    this.onChapterNav,
    this.onOpenContents,
    this.scroll,
    this.languageId,
    this.textSize = 18,
    required this.onTap,
    required this.onDoubleTap,
    this.onTripleTap,
    this.onLongPress,
    this.onMultiTermSelectionStart,
    this.onMultiTermSelectionComplete,
    this.onMultiTermSelectionCancel,
  });

  @override
  State<EpubChapterView> createState() => _EpubChapterViewState();
}

class _EpubChapterViewState extends State<EpubChapterView> {
  InAppWebViewController? _controller;
  bool _pageReady = false;
  double _zoom = 1.0;

  /// The block's configuration last known to be in the page, and a guard so
  /// only one reconcile is queued per frame.  See [_reconcileChapterNav].
  String? _navPushed;
  bool _navReconcileScheduled = false;
  int _navRetries = 0;

  /// The page reports `luteEpubReady` once it has mounted the word spans
  /// and painted the status colours.  Until then the WebView is showing
  /// the book's own raw markup -- no status colours, no book styling --
  /// which reads as a broken page rather than a loading one, so a veil
  /// covers it (see [build]).
  bool _chapterReady = false;

  /// Set once the veil finished fading, so it leaves the tree instead of
  /// sitting invisible above the WebView for the life of the chapter.
  bool _veilGone = false;

  /// Lifts the veil when the page cannot report: a chapter restored from
  /// an offline pack rendered before [luteEpubReady] existed never calls
  /// it, and a load that never completes must not hang the reader.
  Timer? _revealTimer;

  /// Local-pack URL to load instead of the server's, set either before
  /// the first build (server already known unreachable) or as a
  /// mid-load fallback after a main-frame error.
  String? _urlOverride;
  bool _decidingUrl = true;
  bool _fellBackToLocal = false;

  /// Fresh theme CSS that landed while the page was still mounting (see
  /// [_refreshPackInBackground]); applied at load stop.
  String? _pendingThemeCss;

  /// Scroll offset to restore after the page loads (per book).
  double? _pendingScrollRestore;
  bool _restoredThisLoad = false;

  /// Latest reported scroll offset, flushed to prefs debounced.
  double _lastScrollTop = 0;
  Timer? _scrollFlushTimer;

  /// A multi-word selection the page opened and has not reported back on.
  ///
  /// The reader holds its own `_isMultiTermSelecting` for the duration,
  /// and it disables page swiping while it is set -- so every path out of
  /// the gesture has to close it.  A press released where it started is
  /// the awkward one: the page reports it as a plain long press, which
  /// opens the term form and never reaches the selection's own callbacks.
  bool _multiSelectActive = false;

  /// Where the last finger landed inside the chapter, in *screen*
  /// coordinates.  A word tap reaches Dart only after the double-tap
  /// window (~250 ms) and the payload carries no geometry, so this is
  /// the only record of which spot the user pressed -- and it is what
  /// anchors the word card.  Without it the reader fell back to the
  /// whole view's rect: the card came up centred at the very top of the
  /// chapter, nowhere near the word.
  Offset? _lastPointerDown;

  /// Anchor rect for the word card: a zero-size rect at the press point,
  /// which [TermTooltipClass] expands into "card above the finger".  The
  /// fallback (a scripted tap, or a tap that never produced a pointer
  /// event) is the view's own box, i.e. the old behaviour.
  Rect _tapAnchor() {
    final at = _lastPointerDown;
    if (at != null) return Rect.fromLTWH(at.dx, at.dy, 0, 0);
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String get _scrollPrefsKey => 'epub_scroll_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    widget.scroll?._turn = _turnByScreen;
    _installSession();
    _loadSavedScroll();
    _decideInitialUrl();
    // Backstop for a navigation that never finishes (server gone, no
    // pack): the veil must not outlive the attempt.
    _revealTimer = Timer(const Duration(seconds: 30), _revealChapter);
  }

  /// Drop the veil.  Idempotent: the page's report, the post-load grace
  /// and the hard timeout all land here.
  void _revealChapter() {
    _revealTimer?.cancel();
    _revealTimer = null;
    if (!mounted || _chapterReady) return;
    setState(() => _chapterReady = true);
  }

  /// Where the first navigation goes.
  ///
  /// The offline pack wins whenever it holds this chapter, online or
  /// not: it is the same document the server renders, read from disk, so
  /// the chapter paints immediately instead of waiting out a server-side
  /// render (a 380 KB chapter costs two to three seconds of that alone).
  /// Two things keep that honest -- the pack is refreshed from the
  /// server after the load ([_onLoadStop]), and the page's status
  /// classes are re-asserted from the reader's model
  /// ([_pushAllStatuses]), so a copy written before the latest status
  /// changes cannot leave stale colours on screen.
  ///
  /// Without a packed copy the server URL is used as before, and a
  /// main-frame failure still falls back to the pack.
  ///
  /// Nothing here touches the network any more: the pack's asset refresh
  /// used to be awaited first (theme only, 1.2 s leash) and on a cold
  /// start that wait was paid on every open while the CDN handshake ran.
  /// The navigation now starts from the on-disk state alone; the refresh
  /// runs behind it and a changed theme is hot-applied when it lands.
  Future<void> _decideInitialUrl() async {
    final localServer = widget.localServer;
    if (localServer == null) {
      if (mounted) setState(() => _decidingUrl = false);
      return;
    }
    unawaited(_refreshPackInBackground());
    Uri? local;
    try {
      local = await localServer.localPageUrl(
        widget.bookId,
        widget.pageNum,
        look: widget.look,
        furigana: widget.furiganaEnabled,
        triple: widget.enableTripleTap,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _urlOverride = local?.toString();
      _decidingUrl = false;
    });
  }

  /// The pack's background refresh: static assets and theme, off the
  /// critical path.  When the theme on the server differs from the
  /// packed copy, its CSS is carried over to the loaded page -- either
  /// right away, or held for [_onLoadStop] when the page is still
  /// mounting (its own request may have reached the local server before
  /// the file was swapped).
  Future<void> _refreshPackInBackground() async {
    String? css;
    try {
      css = await widget.refreshPackAssets?.call();
    } catch (_) {
      return; // Offline: the packed copies still work.
    }
    if (css == null || css.isEmpty || !mounted) return;
    if (_pageReady) {
      await _applyThemeCss(css);
    } else {
      _pendingThemeCss = css;
    }
  }

  /// Swaps the page's theme stylesheet for the fresh CSS.
  ///
  /// The packed `<link>` is removed and the new rules appended as a
  /// `<style>` -- later in the cascade than anything the page shipped
  /// with, so the new palette wins without a reload (a reload would
  /// re-mount the whole chapter, seconds on this device).
  Future<void> _applyThemeCss(String css, [InAppWebViewController? page]) async {
    final controller = page ?? _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source: '(function(){var css=${jsonEncode(css)};'
            'var link=document.querySelector(\'link[href*="theme/current"]\');'
            'if(link&&link.parentNode){link.parentNode.removeChild(link);}'
            'var style=document.createElement("style");'
            'style.id="lute-theme-live";style.textContent=css;'
            'document.head.appendChild(style);})()',
      );
    } catch (_) {
      // Mid-navigation: the next load reads the swapped file anyway.
    }
  }

  /// The server said unreachable but a navigation was already under
  /// way: if the pack has the chapter, reload it locally, once.
  Future<void> _fallbackToLocal() async {
    if (_fellBackToLocal || _urlOverride != null) return;
    final localServer = widget.localServer;
    if (localServer == null) return;
    _fellBackToLocal = true;
    try {
      final local = await localServer.localPageUrl(
        widget.bookId,
        widget.pageNum,
        look: widget.look,
        furigana: widget.furiganaEnabled,
        triple: widget.enableTripleTap,
      );
      if (local == null || !mounted) return;
      setState(() {
        _urlOverride = local.toString();
        // A fresh navigation: veil the raw markup again until this copy
        // reports, and restart the backstop.
        _chapterReady = false;
        _veilGone = false;
      });
      _revealTimer?.cancel();
      _revealTimer = Timer(const Duration(seconds: 30), _revealChapter);
      await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(local.toString())));
    } catch (_) {
      // Offline without a pack: leave the server's error page showing.
    }
  }

  /// The multi-user session cookie must sit in the WebView cookie store
  /// before the first request: only the initial navigation can carry
  /// custom headers, and the page's own subresources (stylesheets,
  /// images, the readings endpoint) cannot.
  Future<void> _installSession() async {
    try {
      await DictionaryService.installSessionCookie(widget.serverUrl);
    } catch (_) {
      // Single-user mode has no cookie to install; the load proceeds.
    }
  }

  Future<void> _loadSavedScroll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_scrollPrefsKey);
      if (saved != null && saved > 0) {
        _pendingScrollRestore = saved;
      }
    } catch (_) {}
  }

  Future<void> _flushScroll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_scrollPrefsKey, _lastScrollTop);
    } catch (_) {}
  }

  String get _serverPageUrl {
    final query = {
      'look': widget.look,
      'furigana': widget.furiganaEnabled ? '1' : '0',
      'triple': widget.enableTripleTap ? '1' : '0',
    };
    final qs = query.entries.map((e) => '${e.key}=${e.value}').join('&');
    return '${widget.serverUrl}/read/epub_render/${widget.bookId}/${widget.pageNum}?$qs';
  }

  String get _pageUrl => _urlOverride ?? _serverPageUrl;

  void _registerHandlers(InAppWebViewController controller) {
    // Keep it: everything that has to reach the page *after* it loaded --
    // the look, furigana, status pushes, zoom, the end-of-chapter block --
    // runs outside the load callbacks, which are the only place this
    // controller was passed in.
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubReady',
      callback: (args) {
        final payload = args.isNotEmpty && args.first is Map
            ? (args.first as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        // One line per chapter: which of the two ways the veil came down,
        // and how long the page took to mount.  A chapter that reports
        // `mounted: false` is the token-mismatch path, which looks like a
        // slow load but is a real failure.
        debugPrint(
          '[epub-ready] ms=${payload['ms']} '
          'mounted=${payload['mounted']} '
          'mismatch=${payload['mismatch']}',
        );
        _revealChapter();
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubWordTap',
      callback: (args) {
        final item = _itemForPayload(args);
        if (item != null && mounted) widget.onTap(item, _tapAnchor());
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubWordDoubleTap',
      callback: (args) {
        final item = _itemForPayload(args);
        if (item != null) widget.onDoubleTap(item);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubWordTripleTap',
      callback: (args) {
        final item = _itemForPayload(args);
        if (item != null) widget.onTripleTap?.call(item);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubWordLongPress',
      callback: (args) {
        final item = _itemForPayload(args);
        if (item != null && mounted) {
          _closeMultiSelection();
          widget.onLongPress?.call(item, _tapAnchor());
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubMultiSelectStart',
      callback: (args) {
        _multiSelectActive = true;
        if (mounted) widget.onMultiTermSelectionStart?.call();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubMultiSelectComplete',
      callback: (args) {
        _multiSelectActive = false;
        final items = _itemsForPayloads(args);
        if (items.isNotEmpty && mounted) {
          widget.onMultiTermSelectionComplete?.call(items, _tapAnchor());
        } else if (mounted) {
          widget.onMultiTermSelectionCancel?.call();
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubMultiSelectCancel',
      callback: (args) {
        _multiSelectActive = false;
        if (mounted) widget.onMultiTermSelectionCancel?.call();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubBlankTap',
      callback: (args) {
        if (mounted) widget.onBlankTap?.call();
      },
    );
    // The end-of-chapter block reports through two channels: `{-1, +1}`
    // for the chapter arrows and a parameter-less call for Contents.  Both
    // are injected by this widget (see [_pushChapterNav]), so they exist
    // even on a chapter the server never rendered a footer for.
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubChapterNav',
      callback: (args) {
        final payload = args.isNotEmpty && args.first is Map
            ? (args.first as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final dir = (payload['dir'] as num?)?.toInt() ?? 0;
        if (dir != 0) widget.onChapterNav?.call(dir > 0 ? 1 : -1);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubTocOpen',
      callback: (args) {
        widget.onOpenContents?.call();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'luteEpubScroll',
      callback: (args) {
        final payload = args.isNotEmpty && args.first is Map
            ? (args.first as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final top = (payload['top'] as num?)?.toDouble() ?? 0;
        // Restoring scrolls the container, which fires the page's scroll
        // listener and reports offset 0 first; only remember offsets the
        // user actually reached after the restore pass.
        if (_restoredThisLoad) {
          _lastScrollTop = top;
          _scrollFlushTimer?.cancel();
          _scrollFlushTimer = Timer(const Duration(seconds: 1), _flushScroll);
        }
      },
    );
  }

  /// Map a page-side tap payload back to the reader's TextItem for that
  /// word.  The paragraph list is the same token stream the page mounted,
  /// so the word id is the key; a stale list (a save raced the tap) falls
  /// back to a synthetic item so the term card still opens.
  ///
  /// Either way the item leaves with the book's language on it (see
  /// [languageId]): the token stream has none, and without one the word
  /// card cannot reach the local dictionary.
  TextItem? _itemForPayload(List<dynamic> args) {
    if (args.isEmpty || args.first is! Map) return null;
    final payload = (args.first as Map).cast<String, dynamic>();
    final wid = (payload['wid'] as num?)?.toInt() ?? 0;
    if (wid <= 0) return null;

    for (final para in widget.paragraphs) {
      for (final item in para.textItems) {
        if (item.wordId == wid) return _withLanguage(item);
      }
    }
    return TextItem(
      text: payload['text']?.toString() ?? '',
      statusClass: '',
      wordId: wid,
      sentenceId: (payload['sentenceId'] as num?)?.toInt() ?? 0,
      paragraphId: (payload['paragraphId'] as num?)?.toInt() ?? 0,
      isStartOfSentence: false,
      order: (payload['order'] as num?)?.toInt() ?? 0,
      langId: widget.languageId,
    );
  }

  /// Rebuild the items for a multi-word selection.
  ///
  /// The page sends one payload per word span inside the swept range.
  /// `order` is the key: it is the token's index in the page, unique and
  /// contiguous, and it is the same index the token stream was rebuilt
  /// with -- so it resolves a payload against the reader's own model even
  /// for a token that carries no word id (a save that raced the gesture,
  /// a word the server has not persisted yet), which [_itemForPayload]
  /// would drop.
  List<TextItem> _itemsForPayloads(List<dynamic> args) {
    if (args.isEmpty || args.first is! List) return const <TextItem>[];
    final byOrder = <int, TextItem>{};
    for (final para in widget.paragraphs) {
      for (final item in para.textItems) {
        byOrder.putIfAbsent(item.order, () => item);
      }
    }
    final items = <TextItem>[];
    for (final raw in args.first as List) {
      if (raw is! Map) continue;
      final payload = raw.cast<String, dynamic>();
      final order = (payload['order'] as num?)?.toInt() ?? -1;
      final known = byOrder[order];
      if (known != null) {
        items.add(_withLanguage(known));
        continue;
      }
      final wid = (payload['wid'] as num?)?.toInt() ?? 0;
      items.add(
        TextItem(
          text: payload['text']?.toString() ?? '',
          statusClass: '',
          wordId: wid > 0 ? wid : null,
          sentenceId: (payload['sentenceId'] as num?)?.toInt() ?? 0,
          paragraphId: (payload['paragraphId'] as num?)?.toInt() ?? 0,
          isStartOfSentence: false,
          order: order,
          langId: widget.languageId,
        ),
      );
    }
    items.sort((a, b) => a.order.compareTo(b.order));
    return items;
  }

  /// The chapter's tokens carry no language, so a word rebuilt from them
  /// cannot route a dictionary lookup.  The book's id is the answer for
  /// every word in the chapter.
  TextItem _withLanguage(TextItem item) {
    final langId = widget.languageId;
    if (item.langId != null || langId == null) return item;
    return item.copyWith(langId: langId);
  }

  Future<void> _runJs(String source) async {
    final controller = _controller;
    if (controller == null || !_pageReady) return;
    try {
      await controller.evaluateJavascript(source: source);
    } catch (_) {
      // The page may be mid-navigation; the next push retries.
    }
  }

  /// Closes a selection the page still considers open, if one is.
  ///
  /// Called on the way into every other word interaction: a long press
  /// that never moved ends the gesture as a long press, and the reader's
  /// "is selecting" flag has to come down with it or page swiping stays
  /// disabled for the rest of the chapter.
  void _closeMultiSelection() {
    if (!_multiSelectActive) return;
    _multiSelectActive = false;
    if (mounted) widget.onMultiTermSelectionCancel?.call();
  }

  /// Stamps the multi-word selection colour into the page.
  ///
  /// The scheme owns it -- it is the same colour the Flutter-rendered
  /// text paints a selection with -- and a stylesheet served from the
  /// server cannot derive a Flutter theme, so it travels as a custom
  /// property the injected class refers to.  Re-stamping on every load
  /// covers a scheme the reader switched to while the chapter was up.
  Future<void> _pushSelectionColor() async {
    final argb = context.multiTermSelectionColor.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final a = (((argb >> 24) & 0xFF) / 255).toStringAsFixed(2);
    await _runJs('''(function () {
  var root = document.documentElement;
  root.style.setProperty('--lute-multisel-bg', 'rgba($r, $g, $b, $a)');
  var s = document.getElementById('lute-epub-multisel');
  if (!s) {
    s = document.createElement('style');
    s.id = 'lute-epub-multisel';
    (document.head || document.documentElement).appendChild(s);
  }
  s.textContent = 'span.textitem.lute-multisel {' +
    'background-color: var(--lute-multisel-bg) !important;}';
})();''');
  }

  /// Pushes the reading pane's text size into the chapter.
  ///
  /// A flow chapter's paragraphs are the book's own, so -- exactly like the
  /// page's own A+/A- controls -- the size is stamped on the chapter
  /// container, which keeps the book's relative sizes (headings, footnotes)
  /// intact.  The page's own `fontSize` key is written too, so a chapter
  /// rendered again later opens at the reader's size rather than at the
  /// book's.  Fixed-layout pages are pixel boxes fitted by the zoom
  /// controls; resizing their text independently would overflow them.
  Future<void> _pushTextSize() async {
    if (widget.chapter.fixedLayout) return;
    final px = widget.textSize.clamp(1, 50);
    await _runJs('''
(function () {
  var body = document.querySelector(
    '#thetext .epub-body:not([data-epub-viewport])');
  if (!body) return 'nohost';
  var root = parseFloat(window.getComputedStyle(document.body).fontSize) || 16;
  body.style.fontSize = (${px.toStringAsFixed(2)} / root) + 'rem';
  try { localStorage.setItem('fontSize', ${px.toStringAsFixed(2)}); } catch (e) {}
  return 'ok';
})()
''');
  }

  /// Lets the book's own margin be the only gutter on a narrow pane.
  ///
  /// The reader page stacks three gaps between the glass and the text: the
  /// pane's padding, the paper sheet's `1rem`, and the margin the book puts
  /// on its own block.  On this device (674 CSS px across) they came to
  /// 48px a side -- an eighth of the column spent on blank, in two visible
  /// steps, because the sheet edge sits between them.  The pane already
  /// drops its share under 48rem; this drops the sheet's, leaving one
  /// margin, the one the book chose.
  ///
  /// A book that brings no margin of its own keeps a small gutter from the
  /// sheet instead -- otherwise its text would sit on the glass, and
  /// "the book decides" would be a bug rather than a rule.  The measured
  /// gutter is published as `--lute-book-gutter` so the end-of-chapter
  /// block can line up with the text column rather than with the sheet.
  Future<void> _pushMargins([InAppWebViewController? page]) async {
    final controller = page ?? _controller;
    if (controller == null || !_pageReady) return;
    if (widget.chapter.fixedLayout) return;
    try {
      await controller.evaluateJavascript(source: _marginsScript);
    } catch (_) {
      // Mid-navigation; the next load injects again.
    }
  }

  Map<int, String> _statusMap(List<Paragraph> paragraphs) {
    final map = <int, String>{};
    for (final para in paragraphs) {
      for (final item in para.textItems) {
        final wid = item.wordId;
        if (wid != null) map[wid] = item.statusClass;
      }
    }
    return map;
  }

  /// Re-assert every word's status in the page from the reader's model.
  ///
  /// The page paints whatever status classes its HTML carried, and a
  /// chapter served from the offline pack carries the ones it had when
  /// the pack was written -- so a word marked known after that would
  /// come back looking new.  One bulk push per load closes the gap; for
  /// a freshly rendered server page it is a no-op rewrite of the same
  /// classes.
  Future<void> _pushAllStatuses(InAppWebViewController controller) async {
    final map = _statusMap(widget.paragraphs);
    if (map.isEmpty) return;
    try {
      await controller.evaluateJavascript(
        source: 'window.LuteEpubBridge && '
            'window.LuteEpubBridge.setStatuses(${jsonEncode(map)})',
      );
    } catch (_) {
      // The page may be mid-navigation; the next load re-asserts.
    }
  }

  /// 墨水屏纸张（Kaleido 3）：最白底、最黑正文、浅彩状态词块。
  ///
  /// 样式本体在 `shared/theme/eink_paper.dart`，与本地书阅读页共用一份 ——
  /// 纸张不该因为书是从服务器来的还是本地导入的而长得不一样。
  ///
  /// eInk 模式下阅读页**不再继承服务器端 `current_theme`**：纸色、墨色、
  /// 状态色三样都直接钉在页面上，于是「打开墨水屏模式就是这套主题」不依赖
  /// 账号级设置；在手机上读深色、在墨水屏上读白纸，互不打架。
  ///
  /// `look == 'night'` 时整块撤销：夜间靠页面的反相滤镜变暗，把纸色钉成
  /// 白色等于把夜间模式钉死。
  Future<void> _pushEInkPaper() async {
    if (!mounted) return;
    // 夜里有三条路能进暗色：EPUB 的 Night 外观、App 主题切成深色、或者
    // 干脆换一本本地书走它自己的夜间开关。任一为"暗"就不注纸张 —— 否则
    // 深色的 App 会给出一张白得刺眼的正文。
    final appLight = Theme.of(context).brightness == Brightness.light;
    final on = context.eInk && appLight && widget.look != 'night';
    await _runJs(eInkPaperScript(enabled: on));
  }

  /// Push the reader's look onto the page.
  ///
  /// Needed on every load, not just when the setting changes: the page's
  /// boot code reads the look out of localStorage, and the pack's local
  /// origin changes port with every launch, so a chapter that the app
  /// served with look=night still starts as "original" (see
  /// [_onLoadStop]).
  Future<void> _pushLook() async {
    await _runJs(
      "window.LuteEpubBridge && window.LuteEpubBridge.setLook('${widget.look}')",
    );
  }

  /// Inject (or update, or remove) the end-of-chapter block.
  ///
  /// Injected from here rather than rendered by the server: a chapter
  /// served from the offline pack is a *stored* document, and packs
  /// written before the feature existed have no footer -- re-rendering a
  /// shelf of books to gain one would be absurd.  The labels are the
  /// app's (l10n) too, so they follow the interface language without a
  /// server round trip.
  ///
  /// `null` removes an existing block, so a chapter that stops being part
  /// of a set (or a fixed-layout page, which has no flow to append to)
  /// cannot keep a stale footer.
  Future<void> _pushChapterNav([InAppWebViewController? page]) async {
    final controller = page ?? _controller;
    if (controller == null) return;
    final nav = widget.chapterNav;
    final config = (nav == null || nav.isEmpty)
        ? 'null'
        : jsonEncode(nav.toJson());
    try {
      // The page answers whether the block actually landed: a push into a
      // document that has not mounted the chapter yet must not be recorded
      // as done, or the numbers stay missing for the rest of the chapter.
      final result = await controller.evaluateJavascript(
        source: _chapterNavScript.replaceFirst('__CONFIG__', config),
      );
      final landed = result == 'ok' || result == 'removed' || result == null;
      _navPushed = landed ? nav?.signature : null;
      if (landed) {
        _navRetries = 0;
      } else {
        _scheduleNavRetry();
      }
    } catch (_) {
      // Mid-navigation; the next load, build or retry injects again.
      _navPushed = null;
      _scheduleNavRetry();
    }
  }

  /// The page was not ready for the block; try again shortly.  Bounded: a
  /// chapter that never mounts is already handled elsewhere, and a timer
  /// that keeps firing would just burn battery on an e-ink device.
  void _scheduleNavRetry() {
    if (_navRetries >= 6) return;
    _navRetries++;
    Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (_navPushed == widget.chapterNav?.signature) return;
      unawaited(_pushChapterNav());
    });
  }

  /// Pushes the block once the page can take it and its wording differs from
  /// what the page last rendered.  Cheap to call from every build: it queues
  /// at most one post-frame pass and does nothing when the block is current.
  void _reconcileChapterNav() {
    if (_controller == null) return;
    if (_navPushed == widget.chapterNav?.signature) return;
    if (_navReconcileScheduled) return;
    _navReconcileScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navReconcileScheduled = false;
      if (!mounted || _controller == null) return;
      if (_navPushed == widget.chapterNav?.signature) return;
      unawaited(_pushChapterNav());
    });
  }

  Brightness? _lastBrightness;

  /// App 主题从深切浅（或反之）时，页面的纸张要跟着换：eInk 的白纸只在
  /// 浅色主题下注入，深色主题意味着"我现在要夜里读"。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness != brightness) {
      _lastBrightness = brightness;
      if (_pageReady) unawaited(_pushEInkPaper());
    }
  }

  @override
  void didUpdateWidget(EpubChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Look / furigana / zoom-relevant settings changed: push them down.
    if (oldWidget.scroll != widget.scroll) {
      if (oldWidget.scroll?._turn == _turnByScreen) {
        oldWidget.scroll?._turn = null;
      }
      widget.scroll?._turn = _turnByScreen;
    }
    if (oldWidget.look != widget.look) {
      _pushLook();
      // 夜间 <-> 白纸切换时那层纸色样式要跟着加/撤（见 _pushEInkPaper）。
      _pushEInkPaper();
    }
    if (oldWidget.textSize != widget.textSize) {
      _pushTextSize();
      // The book's own gutter is in `em`, so it grew with the type: the
      // block that aligns to the text column has to be re-measured.
      _pushMargins();
    }
    if (oldWidget.furiganaEnabled != widget.furiganaEnabled) {
      _runJs(
        'window.LuteEpubBridge && window.LuteEpubBridge.setFurigana(${widget.furiganaEnabled})',
      );
    }

    // The end-of-chapter block is reconciled from [build] rather than here:
    // it depends on a list that arrives when it arrives, and a build is the
    // one moment guaranteed to follow every change of that list.

    // Status changes arrive as rebuilt paragraph lists; only the changed
    // words are pushed, so the page does not repaint the whole chapter.
    if (!identical(oldWidget.paragraphs, widget.paragraphs)) {
      final oldStatuses = _statusMap(oldWidget.paragraphs);
      final newStatuses = _statusMap(widget.paragraphs);
      newStatuses.forEach((wid, cls) {
        if (oldStatuses[wid] != cls) {
          _runJs('window.LuteEpubBridge && window.LuteEpubBridge.setStatus($wid, "$cls")');
        }
      });
    }
  }

  Future<void> _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    if (!mounted) return;
    setState(() => _pageReady = true);
    // `127.0.0.1` means the offline pack served this chapter, not the
    // server -- worth knowing when a page change looks like it did not
    // reach the network.
    debugPrint('[epub-ready] load-stop host=${url?.host}');

    // A theme refresh that landed mid-mount: the page's own request may
    // have reached the local server before the packed file was swapped,
    // so the mount can carry the previous palette.  Same CSS either way
    // when the request came after the swap -- re-appending it is a no-op.
    final pendingTheme = _pendingThemeCss;
    _pendingThemeCss = null;
    if (pendingTheme != null && pendingTheme.isNotEmpty) {
      await _applyThemeCss(pendingTheme, controller);
    }

    // A packed copy carries the status classes it had when it was
    // written; the reader's model is the authority.  One DOM pass, once
    // per load -- the per-word bridge call would be thousands of
    // subtree queries on a full chapter.
    await _pushAllStatuses(controller);

    // The page decides its look from its own localStorage, not from the
    // class the document arrived with: `mount()` re-derives it, and the
    // pack is served from `http://127.0.0.1:<random port>`, a brand-new
    // origin every launch -- so the stored value is absent and the page
    // boots as "original" even when the chapter was fetched with
    // look=night.  Assert the reader's setting once per load; the chips
    // then apply instantly and a fresh chapter starts on the right look.
    await _pushLook();

    // 墨水屏：把白纸 + 纯黑墨 + 浅彩状态钉上去（夜间外观时是撤销）。
    // 紧随 look 之后，页面一挂好就是最终颜色，不会先闪一帧服务器主题色。
    await _pushEInkPaper();

    // Report clicks that miss every word.  Wired here rather than in the
    // page: a pack written before this existed has no such bridge, and its
    // HTML is only replaced when the chapter is re-rendered.  Capture
    // phase, so it runs before the page's own handler and does not depend
    // on it; `__luteBlankTapWired` keeps a reload from stacking listeners.
    try {
      await controller.evaluateJavascript(
        source: r"""
(function () {
  if (window.__luteBlankTapWired) return;
  window.__luteBlankTapWired = true;
  document.addEventListener('click', function (event) {
    var target = event.target;
    if (target && target.closest && target.closest('span.textitem.word')) return;
    /* The injected end-of-chapter block is chrome, not text: pressing its
       buttons must not also count as "a tap on empty space" (which in
       fullscreen mode toggles the app's own bars). */
    if (target && target.closest && target.closest('.lute-chapter-nav')) return;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('luteEpubBlankTap');
    }
  }, true);
})();
""",
      );
    } catch (_) {
      // The page may be mid-navigation; the next load retries.
    }

    // The long press, the gesture that opens a word's edit form on the
    // Flutter-rendered text.  The page settles clicks (single / double /
    // triple) but never sees a press that stops being one, and Chromium
    // has no Dart-side long press to forward -- so the gesture is
    // measured in the document, like the blank-tap listener above, and
    // reported through the same bridge.
    try {
      await controller.evaluateJavascript(source: _longPressScript);
    } catch (_) {
      // The page may be mid-navigation; the next load retries.
    }

    await _pushSelectionColor();
    await _pushTextSize();
    // After the type size: the book's own gutter is in `em`, so it has to
    // be measured against the type that is actually in the page.
    await _pushMargins(controller);

    // Last in the DOM pass: the block is appended *after* the chapter, so
    // it must not be in the tree while the page aligns its word spans.
    await _pushChapterNav(controller);

    // 章末块自带一份样式（灰色 chrome + 自己的 !important），刚注入完要再
    // 盖一次纸张样式，否则「END OF CHAPTER」那几行还是浅灰 —— 墨水屏上等于
    // 看不清，而它是翻页的主要入口。
    await _pushEInkPaper();

    // The page reports readiness at DOMContentLoaded, i.e. before the
    // load event, so a live chapter has already lifted the veil here.
    // One that did not is a chapter rendered before the callback existed
    // (a stale offline-pack copy): show it after a beat rather than keep
    // the spinner up.  The load event cannot fire while the mount runs
    // (same thread), so this never uncovers an unmounted chapter.
    if (!_chapterReady) {
      debugPrint('[epub-ready] no report; revealing after load-stop');
      _revealTimer?.cancel();
      _revealTimer = Timer(const Duration(milliseconds: 800), _revealChapter);
    }
    try {
      final zoom = await controller.evaluateJavascript(
        source: 'window.LuteEpubBridge ? window.LuteEpubBridge.getZoom() : 1',
      );
      if (zoom is num && mounted) setState(() => _zoom = zoom.toDouble());
    } catch (_) {}

    // Refresh the pack from the server.  This used to run only when the
    // server had served the page; now the pack serves it too, and the
    // pack has to keep up with the server (new statuses, text fixes) or
    // it would stay at whatever it held when it was written.
    if (url != null &&
        (url.host != '127.0.0.1' || ServerStatusManager.isReachable)) {
      widget.onOnlineChapterLoaded?.call();
    }

    // Restore the reading position once per load; a frame later the
    // page-side restoreScroll also waits for images to settle.
    if (!_restoredThisLoad) {
      _restoredThisLoad = true;
      final top = _pendingScrollRestore;
      if (top != null && top > 0) {
        await controller.evaluateJavascript(
          source: 'window.LuteEpubBridge && window.LuteEpubBridge.restoreScroll($top)',
        );
      }
    }
  }

  /// A main-frame failure on the server URL is usually a stale
  /// "reachable" flag (signal dropped mid-session); the local pack, if
  /// any, takes over.
  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (request.isForMainFrame == true) {
      // Whatever landed (the server's error page, or nothing) is what the
      // reader should be looking at -- not a spinner over it.
      _revealChapter();
    }
    if (request.isForMainFrame == true && _urlOverride == null) {
      _fallbackToLocal();
    }
  }

  /// Basic Auth for a proxy in front of the server: answer only
  /// challenges for the configured host, cancel everything else, so
  /// credentials never leak to third-party hosts (same rule as the
  /// player WebView).
  Future<HttpAuthResponse?> _onReceivedHttpAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  ) async {
    final serverHost = Uri.tryParse(widget.serverUrl)?.host ?? '';
    final user = SessionManager.basicAuthUser;
    if (serverHost.isEmpty ||
        user.isEmpty ||
        challenge.protectionSpace.host != serverHost) {
      return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
    }
    return HttpAuthResponse(
      username: user,
      password: SessionManager.basicAuthPassword,
      action: HttpAuthResponseAction.PROCEED,
    );
  }

  Future<void> _zoomBy(double factor) async {
    await _runJs('window.LuteEpubBridge && window.LuteEpubBridge.setZoom($factor)');
    final controller = _controller;
    if (controller == null) return;
    try {
      final zoom = await controller.evaluateJavascript(
        source: 'window.LuteEpubBridge ? window.LuteEpubBridge.getZoom() : 1',
      );
      if (zoom is num && mounted) setState(() => _zoom = zoom.toDouble());
    } catch (_) {}
  }

  /// Scrolls the chapter by one screen, for the physical page keys.
  ///
  /// `true` = the key was used.  When the page cannot scroll further in that
  /// direction it answers `edge`, and the reader turns the page instead --
  /// that is the only way a key-only reader gets from one chapter to the
  /// next without touching the screen.
  Future<bool> _turnByScreen(int direction) async {
    final controller = _controller;
    // Not ready yet: swallow the key rather than jump a page on a document
    // the user has not seen.
    if (controller == null || !_pageReady) return true;
    try {
      final result = await controller.evaluateJavascript(
        source: _pageTurnScript.replaceFirst('__DIR__', '$direction'),
      );
      debugPrint('[pagekey] turn $direction -> $result');
      return result?.toString() != 'edge';
    } catch (_) {
      // Mid-navigation; a key press must not surface as an error.
      return true;
    }
  }

  @override
  void dispose() {
    _scrollFlushTimer?.cancel();
    _revealTimer?.cancel();
    // One chapter is on screen at a time.  Guarded, because with a fresh
    // page key the replacement may already have claimed the slot.
    final slot = widget.scroll;
    if (slot != null && slot._turn == _turnByScreen) slot._turn = null;
    // Persist whatever offset was last reported.
    if (_lastScrollTop > 0) {
      unawaited(_flushScroll());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_decidingUrl) {
      // One async hop offline: pack lookup + local server start.
      return const SizedBox.shrink();
    }
    // The block's wording can change after the page has loaded -- the
    // chapter list arrives with the neighbours' numbers, a font change
    // re-renders the chapter -- and none of that reloads the document.
    // Reconcile it from the build, which every one of those changes goes
    // through, instead of relying on a widget-update hook.
    _reconcileChapterNav();
    return Stack(
      children: [
        // Records where the finger came down -- the tap itself is settled
        // by the page (double/triple-tap detection needs the click
        // stream), so Dart never sees a GestureDetector callback inside
        // the WebView.  A raw [Listener] sits on the hit-test path
        // regardless of which recognizer wins the arena, which is what
        // keeps the word card anchored under the finger.
        Listener(
          onPointerDown: (event) {
            _lastPointerDown = event.position;
            // Anything pressed inside the chapter dismisses an open word
            // card -- including pressing another word, which re-opens the
            // card a moment later from the page's own tap handler.
            widget.onPress?.call();
          },
          child: InAppWebView(
            key: ValueKey('epub-webview-${widget.bookId}-${widget.pageNum}'),
            initialUrlRequest: URLRequest(url: WebUri(_pageUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              // Zoom runs through the bridge (the page disables the
              // viewport gesture so double-tap stays a status cycle).
              supportZoom: false,
              transparentBackground: true,
            ),
            // A platform view only receives pointer events while *its* own
            // gesture recognizers hold the arena (see
            // render/rendering/platform_view.dart: "as long as the gesture
            // arena is unresolved, the recognizer caches all pointer
            // events").  The default set is empty, so nothing in Flutter
            // ever claims the arena, and the cached sequence is replayed to
            // Chromium only once the finger goes up.  Taps survived that
            // (the page gets down+up in one go) and so did flings (the
            // replay carries velocity), but a drag could not follow the
            // finger: measured on the OnePlus, a 1600 px slow drag over 3 s
            // moved the chapter 24 px, while a fast 1000 px swipe carried
            // it hundreds.  Handing every pointer that starts inside the
            // WebView straight to Chromium is what makes dragging scroll.
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
            },
            onWebViewCreated: _registerHandlers,
            onLoadStop: _onLoadStop,
            onReceivedError: _onReceivedError,
            onReceivedHttpAuthRequest: _onReceivedHttpAuthRequest,
          ),
        ),
        // Zoom controls for fixed-layout chapters (fit-to-width pages
        // that cannot reflow); reflowing chapters read at the book's own
        // text size and pinch-zooming the viewport is off.
        if (widget.chapter.fixedLayout)
          Positioned(
            right: 8,
            bottom: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ZoomButton(
                  icon: Icons.add,
                  tooltip: 'Zoom in',
                  onPressed: () =>
                      _zoomBy(((_zoom * 1.2 * 100).round()) / 100),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${(_zoom * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.remove,
                  tooltip: 'Zoom out',
                  onPressed: () =>
                      _zoomBy(((_zoom / 1.2 * 100).round()) / 100),
                ),
                const SizedBox(height: 6),
                _ZoomButton(
                  icon: Icons.fit_screen,
                  tooltip: 'Fit page',
                  onPressed: () => _zoomBy(1),
                ),
              ],
            ),
          ),
        // The chapter is in the document the moment it parses, but it is
        // the book's own markup until the page mounts the word spans --
        // no status colours, no book styling.  A chapter that looks
        // half-broken for a few seconds reads worse than a spinner, so
        // the veil stays until the page reports (or a backstop fires).
        if (!_veilGone)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _chapterReady,
              child: AnimatedOpacity(
                opacity: _chapterReady ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                onEnd: () {
                  if (_chapterReady && mounted) {
                    setState(() => _veilGone = true);
                  }
                },
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: tooltip,
      button: true,
      child: IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        iconSize: 20,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.7),
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// Out-of-band control of a chapter's scroll position.
///
/// A chapter is one long document inside a platform view: the reader has no
/// scroll controller for it, so the physical page keys (the main way through
/// a book on this device) had nothing to move.  The view hands its scroller
/// to this slot when it mounts and clears it when it goes away.
class EpubChapterScroll {
  Future<bool> Function(int direction)? _turn;

  bool get attached => _turn != null;

  /// Scrolls one screen.  `true` means the key was used (the chapter moved,
  /// or the view could not tell); `false` means it is already at that end,
  /// which is the reader's cue to leave the chapter instead.
  Future<bool> turn(int direction) async {
    final handler = _turn;
    if (handler == null) return false;
    return handler(direction);
  }
}

/// Scrolls the chapter by one screen (`__DIR__` = -1 up / +1 down).
///
/// Done page-side so the units are the document's, and reported back as
/// `moved` / `edge` -- the caller needs the difference: at the edge the key
/// has to turn the page instead.
const String _pageTurnScript = r"""
(function (dir) {
  var doc = document.scrollingElement || document.documentElement;
  if (!doc) return 'edge';
  var step = Math.round(doc.clientHeight * 0.92);
  var before = doc.scrollTop;
  doc.scrollTop = before + dir * step;
  if (doc.scrollTop !== before) return 'moved';
  /* Some look modes scroll a container instead of the document. */
  var pane = document.getElementById('thetext');
  if (pane && pane.scrollHeight > pane.clientHeight + 4) {
    var paneBefore = pane.scrollTop;
    pane.scrollTop = paneBefore + dir * step;
    return pane.scrollTop !== paneBefore ? 'moved' : 'edge';
  }
  return 'edge';
})(__DIR__)
""";

/// Builds the end-of-chapter block inside the page (`__CONFIG__` is
/// replaced with the JSON of [ChapterNavConfig]).
///
/// Rules the design settled on, and why they are spelled out in CSS
/// rather than left to the browser: square corners, hairline borders, no
/// shadow and no transition -- this app runs on an e-ink phone, where a
/// radius renders as a smudge and a 200 ms fade leaves a ghost.  Buttons
/// are 56 px tall (48 is the touch floor, and a chapter arrow is pressed
/// with a thumb at the very bottom of a scrolled page); the Contents row
/// is 48.
///
/// Colour comes from `currentColor`, which the two paper looks resolve to
/// the *pinned* `#1c1b1f` -- the same value the chapter text is pinned to,
/// because `--paper-filter` inverts the whole sheet.  The theme look has
/// no paper and inherits the theme's `--font-color`.  The pressed state
/// paints the block with `currentColor` and the label with the paper
/// colour, i.e. the same inversion the looks already perform.
///
/// The block is appended *inside* `.epub-body`, not next to it: that is
/// the element the paper looks put `--paper-filter` on, and a pinned
/// `#1c1b1f` outside it stays dark on a dark sheet (measured: a sibling
/// block rendered at 1.2:1, invisible).  Living there also means the
/// block sits in the chapter's own scrolled flow, with the text column's
/// width, and scrolls away with the words; a fixed bar would permanently
/// eat 60 px of an already narrow column.
///
/// The layout properties carry `!important` because the block lands in
/// the *book's* scoped stylesheet territory (`div` / `p` rules exist in
/// real EPUBs); ours must not be re-margined by the book.
const String _chapterNavScript = r"""
(function () {
  var cfg = __CONFIG__;
  var STYLE_ID = 'lute-chapter-nav-style';
  var CSS = [
    /* The block sits in .epub-body, which now runs to the glass; the text
       column does not, so it takes the book's own gutter (published by
       [_marginsScript]) and keeps the buttons under the paragraphs. */
    '.lute-chapter-nav{margin:44px var(--lute-book-gutter,0) 36px !important;',
    '  padding:0 !important;',
    '  text-align:center !important;',
    '  font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;',
    '  font-size:13px;line-height:1.2;color:#1c1b1f;}',
    '.lute-chapter-nav[data-look="theme"]{color:var(--font-color,inherit);}',
    /* Every part of the block is a `div` of its own; a book that styles
       `.epub-body div` outranks a bare class selector, so the layout
       properties are `!important` here too. */
    '.lute-nav-rule{width:64px;height:1px;margin:0 auto 20px !important;',
    '  padding:0 !important;background:currentColor !important;opacity:.4;}',
    '.lute-nav-end{font-size:11px;letter-spacing:3px;text-transform:uppercase;',
    '  opacity:.62;margin:0 0 20px !important;padding:0 !important;}',
    '.lute-nav-row{display:flex !important;gap:12px;',
    '  margin:0 !important;padding:0 !important;}',
    '.lute-nav-btn{box-sizing:border-box;flex:1 1 0;min-width:0;min-height:56px;',
    '  display:flex;flex-direction:column;align-items:center;justify-content:center;',
    '  gap:3px;padding:6px 4px;margin:0 !important;',
    '  border:1px solid currentColor !important;border-radius:0 !important;',
    '  background:transparent !important;color:inherit;font:inherit;',
    '  text-align:center;box-shadow:none !important;outline:none;',
    '  -webkit-tap-highlight-color:transparent;}',
    '.lute-nav-main,.lute-nav-sub{color:inherit !important;}',
    '.lute-nav-btn:active{background:currentColor !important;}',
    '.lute-nav-btn:active .lute-nav-main,',
    '.lute-nav-btn:active .lute-nav-sub{color:#fff !important;}',
    '.lute-chapter-nav[data-look="theme"] .lute-nav-btn:active .lute-nav-main,',
    '.lute-chapter-nav[data-look="theme"] .lute-nav-btn:active .lute-nav-sub',
    '  {color:var(--background-color,#fff) !important;}',
    '.lute-nav-main{font-size:13px;font-weight:500;}',
    '.lute-nav-sub{font-size:11px;opacity:.62;}',
    '.lute-nav-toc{display:flex !important;width:100%;min-height:48px;',
    '  margin:12px 0 0 !important;padding:0 !important;flex:0 0 auto;}'
  ].join('\n');

  function callFlutter(name, payload) {
    if (window.flutter_inappwebview &&
        typeof window.flutter_inappwebview.callHandler === 'function') {
      window.flutter_inappwebview.callHandler(name, payload || {});
    }
  }

  /* The stylesheet is injected once per document; the block itself is
     rebuilt on every call, so a config change (the chapter list arriving
     with the neighbours' numbers) simply replaces it. */
  if (!document.getElementById(STYLE_ID)) {
    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = CSS;
    document.head.appendChild(style);
  }
  var previous = document.querySelector('.lute-chapter-nav');
  if (previous && previous.parentNode) previous.parentNode.removeChild(previous);
  if (!cfg) return 'removed';

  /* Inside .epub-body: that is the filtered element the paper looks
     invert, so the block's ink is inverted with the text.  The fallbacks
     cover a chapter whose markup has no .epub-body wrapper. */
  var host = document.querySelector('#epub-chapter .epub-body') ||
             document.getElementById('epub-chapter') ||
             document.getElementById('thetext');
  if (!host) return 'nohost';

  function makeButton(target, extraClass) {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'lute-nav-btn' + (extraClass ? ' ' + extraClass : '');
    var main = document.createElement('span');
    main.className = 'lute-nav-main';
    main.textContent = target.label || '';
    button.appendChild(main);
    if (target.sub) {
      var sub = document.createElement('span');
      sub.className = 'lute-nav-sub';
      sub.textContent = target.sub;
      button.appendChild(sub);
    }
    return button;
  }

  function wire(button, handler) {
    button.addEventListener('click', function (event) {
      /* The page's own capture-phase listener reports clicks that miss a
         word; this block is chrome, and its press must not also toggle the
         app's bars (see the blank-tap wiring in EpubChapterView). */
      event.preventDefault();
      event.stopPropagation();
      handler();
    });
  }

  /* A <section>, not a <div>: EPUB stylesheets style divs (`.body` carries
     the book's own side margins) and this block must not inherit them. */
  var wrap = document.createElement('section');
  wrap.className = 'lute-chapter-nav';
  wrap.setAttribute('data-look', cfg.look || 'theme');
  wrap.setAttribute('role', 'group');

  var rule = document.createElement('div');
  rule.className = 'lute-nav-rule';
  wrap.appendChild(rule);

  if (cfg.end) {
    var end = document.createElement('div');
    end.className = 'lute-nav-end';
    end.textContent = cfg.end;
    wrap.appendChild(end);
  }

  var row = document.createElement('div');
  row.className = 'lute-nav-row';
  if (cfg.prev) {
    var prev = makeButton(cfg.prev);
    wire(prev, function () { callFlutter('luteEpubChapterNav', {dir: -1}); });
    row.appendChild(prev);
  }
  if (cfg.next) {
    var next = makeButton(cfg.next);
    wire(next, function () { callFlutter('luteEpubChapterNav', {dir: 1}); });
    row.appendChild(next);
  }
  if (row.childNodes.length) wrap.appendChild(row);

  if (cfg.contents) {
    var toc = makeButton({label: cfg.contents}, 'lute-nav-toc');
    wire(toc, function () { callFlutter('luteEpubTocOpen', {}); });
    wrap.appendChild(toc);
  }

  host.appendChild(wrap);
  return 'ok';
})();
""";

/// Wires a long press on a word into the bridge.
///
/// The page's own click listener settles *clicks* -- it counts them inside
/// a 300 ms window and reports the settled one -- and a press that never
/// becomes a click never reaches it.  The gesture the Flutter-rendered text
/// maps to the term edit form (a ~500 ms hold) therefore had no equivalent
/// in a chapter: nothing happened at all.
///
/// Measured here rather than in the page template for the same reason the
/// blank-tap listener is: an offline pack stores the chapter document
/// verbatim, so every chapter written before the wiring existed would stay
/// without it until the book was re-rendered.
///
/// The press that leaves no click still produces one: Chromium fires
/// `click` on release, which the page would settle as a word tap and open
/// the word card on top of the form.  It is swallowed in the capture
/// phase -- capture runs before the page's own (bubble-phase) document
/// listener, so `stopPropagation` there is enough, and it costs nothing
/// when no press was held.  A press that drifts (a scroll, a finger that
/// slides off the word) is dropped rather than counted.
///
/// The press is only the *start* of the gesture, though: past [LONG_MS]
/// the finger is still down, and dragging it across the paragraph extends
/// the selection to every word between the two ends -- the EPUB page's
/// answer to the multi-word selection the Flutter-rendered text gets from
/// `onLongPressMoveUpdate`.  A press that is released without having
/// moved is a plain long press and opens the term form for that one word,
/// so the gesture the reader already knows is unchanged.
///
/// Two things about the drag are not obvious.  A touch pointer gets
/// *implicit pointer capture* on `pointerdown`, so every `pointermove`
/// the document sees still carries the pressed span as its target -- the
/// finger's actual position has to be asked for with `elementFromPoint`.
/// And the page scrolls under a drag, which would both move the words out
/// from under the finger and turn the gesture into a flick: `touchmove`
/// is prevented for the duration, which only works because the listener
/// is registered (non-passive) before any touch begins, and because a
/// press that moved before the hold landed was already dropped -- so the
/// first `touchmove` of a drag is always the first one the page sees.
const String _longPressScript = r"""
(function () {
  if (window.__luteSelectionWired) return;
  window.__luteSelectionWired = true;

  var LONG_MS = 500;
  var MOVE_TOL = 14;
  var timer = null;
  var startX = 0, startY = 0;
  var startSpan = null;
  var endSpan = null;
  var selecting = false;
  var held = false;

  function wordSpan(node) {
    return node && node.closest ? node.closest('span.textitem.word') : null;
  }

  function tokenSpan(node) {
    return node && node.closest ? node.closest('span.textitem') : null;
  }

  function payloadOf(el) {
    return {
      wid: parseInt(el.dataset.wid || '0', 10),
      text: el.dataset.text || '',
      sentenceId: parseInt(el.dataset.sentenceId || '0', 10),
      paragraphId: parseInt(el.dataset.paragraphId || '0', 10),
      order: parseInt(el.dataset.order || '0', 10)
    };
  }

  function call(name, arg) {
    if (window.flutter_inappwebview &&
        window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(name, arg);
    }
  }

  function order(el) {
    return parseInt(el.dataset.order || '0', 10);
  }

  /* The painted range is the closed order interval between the two ends:
     `data-order` is the token's index in the page and is unique and
     contiguous across it, so the interval is exactly the words the reader
     swept over -- including the ones it skipped past, which is what the
     Flutter-rendered text does too. */
  function paint() {
    var marked = document.querySelectorAll('span.textitem.lute-multisel');
    for (var i = 0; i < marked.length; i++) {
      marked[i].classList.remove('lute-multisel');
    }
    if (!startSpan || !endSpan) return;
    var lo = Math.min(order(startSpan), order(endSpan));
    var hi = Math.max(order(startSpan), order(endSpan));
    var all = document.querySelectorAll('span.textitem');
    for (var j = 0; j < all.length; j++) {
      var o = order(all[j]);
      if (o >= lo && o <= hi) all[j].classList.add('lute-multisel');
    }
  }

  function reset() {
    if (timer) { clearTimeout(timer); timer = null; }
    selecting = false;
    startSpan = null;
    endSpan = null;
    var marked = document.querySelectorAll('span.textitem.lute-multisel');
    for (var i = 0; i < marked.length; i++) {
      marked[i].classList.remove('lute-multisel');
    }
    var host = document.getElementById('thetext');
    if (host) host.style.touchAction = '';
  }

  document.addEventListener('pointerdown', function (event) {
    reset();
    held = false;
    var el = wordSpan(event.target);
    if (!el) return;
    startSpan = el;
    endSpan = el;
    startX = event.clientX;
    startY = event.clientY;
    timer = setTimeout(function () {
      timer = null;
      selecting = true;
      held = true;
      /* Chromium's own long press starts a selection on the word; the
         form may follow, and a selection left under it reappears when the
         form closes. */
      var sel = window.getSelection && window.getSelection();
      if (sel && sel.removeAllRanges) sel.removeAllRanges();
      var host = document.getElementById('thetext');
      if (host) host.style.touchAction = 'none';
      paint();
      call('luteEpubMultiSelectStart', null);
    }, LONG_MS);
  }, true);

  document.addEventListener('pointermove', function (event) {
    if (selecting) {
      /* Implicit pointer capture pins `event.target` to the pressed span,
         so the finger's real position has to be resolved here. */
      var under = document.elementFromPoint(event.clientX, event.clientY);
      var el = wordSpan(under) || tokenSpan(under);
      if (el && el !== endSpan) {
        endSpan = el;
        paint();
      }
      return;
    }
    if (!timer) return;
    if (Math.abs(event.clientX - startX) > MOVE_TOL ||
        Math.abs(event.clientY - startY) > MOVE_TOL) {
      reset();
    }
  }, true);

  /* Non-passive and registered before any touch: the drag's first
     `touchmove` is the page's first too, so preventing it here keeps the
     chapter from scrolling out from under a moving finger. */
  document.addEventListener('touchmove', function (event) {
    if (selecting) event.preventDefault();
  }, { capture: true, passive: false });

  document.addEventListener('pointerup', function (event) {
    if (timer) { reset(); return; }
    if (!selecting) return;

    var lo = Math.min(order(startSpan), order(endSpan));
    var hi = Math.max(order(startSpan), order(endSpan));
    /* Every token in the range, not just the words: the term is built
       from the text the reader swept over, and on a language that spaces
       its words that text is what sits between them -- dropping the
       non-words would join "make" and "up" into "makeup".  The reader
       trims the ends, and it is what the Flutter-rendered text hands
       over for the same gesture. */
    var all = document.querySelectorAll('span.textitem');
    var payloads = [];
    for (var i = 0; i < all.length; i++) {
      var o = order(all[i]);
      if (o >= lo && o <= hi) payloads.push(payloadOf(all[i]));
    }
    payloads.sort(function (a, b) { return a.order - b.order; });

    /* Counted in words, not tokens: a drag that ends on a space still
       swept over one word, and it has to read as the long press the
       reader already knows. */
    var first = null;
    var words = 0;
    for (var k = 0; k < payloads.length; k++) {
      if (payloads[k].wid > 0) {
        words += 1;
        if (!first) first = payloads[k];
      }
    }

    reset();
    if (words === 0) {
      call('luteEpubMultiSelectCancel', null);
    } else if (words === 1) {
      /* Released where it started: the long press the reader already
         knows, not a selection. */
      call('luteEpubWordLongPress', first);
    } else {
      call('luteEpubMultiSelectComplete', payloads);
    }
  }, true);

  document.addEventListener('pointercancel', function (event) {
    if (selecting) call('luteEpubMultiSelectCancel', null);
    reset();
  }, true);

  /* The release of a held press is still a click to the page.  Capture
     phase, so it is gone before the page's own listener can settle it. */
  document.addEventListener('click', function (event) {
    if (!held) return;
    held = false;
    event.preventDefault();
    event.stopPropagation();
  }, true);

  document.addEventListener('contextmenu', function (event) {
    if (!wordSpan(event.target)) return;
    event.preventDefault();
  }, true);
})();
""";

/// Collapses the reader page's side margins down to the book's own.
///
/// Runs after every chapter load (and again when the type size changes, as
/// the book's margin is authored in `em`).  The stylesheet is a single
/// element kept across looks; only narrow panes are touched, so a tablet or
/// a desktop browser is unaffected.
const String _marginsScript = r"""
(function () {
  var chapter = document.getElementById('epub-chapter');
  var body = document.querySelector('#epub-chapter .epub-body');
  if (!chapter || !body) return 'nohost';

  /* What the book itself leaves between the sheet edge and its text.  Read
     off the inner block's computed box: those margins are the book's and do
     not move when ours do, so measuring cannot make the result oscillate. */
  var inner = body.firstElementChild || body;
  var cs = getComputedStyle(inner);
  var left = (parseFloat(cs.marginLeft) || 0) + (parseFloat(cs.paddingLeft) || 0);
  var right = (parseFloat(cs.marginRight) || 0) + (parseFloat(cs.paddingRight) || 0);
  var own = Math.min(left, right);

  /* Only a book that brings its own gutter gets ours removed: a bare one
     keeps a small gutter from the sheet so its text never sits on the
     glass. */
  var tighter = own >= 6;
  var gutter = tighter ? '0' : '0.9rem';

  var css =
    '@media (max-width: 48rem) {' +
      'div#thetext.epub-text-container.epub-look-original #epub-chapter,' +
      'div#thetext.epub-text-container.epub-look-night #epub-chapter {' +
        'padding-left:' + gutter + ' !important;' +
        'padding-right:' + gutter + ' !important;' +
        'margin-left:0 !important;' +
        'margin-right:0 !important;' +
        /* The sheet had 0.5rem of outer margin; with none it fills the
           pane, which is what its min-height was compensating for. */
        'min-height:100% !important;' +
      '}' +
    '}';

  var style = document.getElementById('lute-epub-margins');
  if (!style) {
    style = document.createElement('style');
    style.id = 'lute-epub-margins';
    (document.head || document.documentElement).appendChild(style);
  }
  if (style.textContent !== css) style.textContent = css;

  /* Published for the end-of-chapter block, which lives in the (now
     full-bleed) .epub-body and aligns to the text column instead. */
  var column = Math.min(own, 64);
  document.documentElement.style.setProperty(
    '--lute-book-gutter', column.toFixed(1) + 'px');

  return tighter ? 'tight' : 'keep';
})();
""";

