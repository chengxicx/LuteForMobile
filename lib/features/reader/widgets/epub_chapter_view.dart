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

  /// Re-fetches the pack's theme (the one asset that is per-user and not
  /// content-addressed) before a chapter is served from the pack.  A
  /// WebView loading the pack cannot revalidate it, so without this a
  /// theme change leaves the reader on the previous palette -- dark
  /// chrome around a white sheet.
  final Future<void> Function()? refreshPackAssets;

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
    this.textSize = 18,
    required this.onTap,
    required this.onDoubleTap,
    this.onTripleTap,
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

  /// Scroll offset to restore after the page loads (per book).
  double? _pendingScrollRestore;
  bool _restoredThisLoad = false;

  /// Latest reported scroll offset, flushed to prefs debounced.
  double _lastScrollTop = 0;
  Timer? _scrollFlushTimer;

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
  Future<void> _decideInitialUrl() async {
    final localServer = widget.localServer;
    if (localServer == null) {
      if (mounted) setState(() => _decidingUrl = false);
      return;
    }
    Uri? local;
    try {
      // Only the theme is awaited, and only briefly.  It is a few KB and
      // the palette is simply wrong without it; the pack's stylesheet and
      // reader scripts are the caller's background job (~200 KB, which
      // cost a measured 2.4 s of blank chapter on every cold open).
      await widget.refreshPackAssets?.call().timeout(
        const Duration(milliseconds: 1200),
      );
    } catch (_) {
      // Offline, or the refresh timed out: the packed copies still work.
    }
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
  TextItem? _itemForPayload(List<dynamic> args) {
    if (args.isEmpty || args.first is! Map) return null;
    final payload = (args.first as Map).cast<String, dynamic>();
    final wid = (payload['wid'] as num?)?.toInt() ?? 0;
    if (wid <= 0) return null;

    for (final para in widget.paragraphs) {
      for (final item in para.textItems) {
        if (item.wordId == wid) return item;
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
    );
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

  @override
  void didUpdateWidget(EpubChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Look / furigana / zoom-relevant settings changed: push them down.
    if (oldWidget.look != widget.look) {
      _pushLook();
    }
    if (oldWidget.textSize != widget.textSize) {
      _pushTextSize();
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

    // Last in the DOM pass: the block is appended *after* the chapter, so
    // it must not be in the tree while the page aligns its word spans.
    await _pushTextSize();
    await _pushChapterNav(controller);

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

  @override
  void dispose() {
    _scrollFlushTimer?.cancel();
    _revealTimer?.cancel();
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
    '.lute-chapter-nav{margin:44px 0 36px !important;padding:0 !important;',
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

