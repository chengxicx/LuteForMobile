import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/dictionary_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/server_status_provider.dart';
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

  final void Function(TextItem item, BuildContext context) onTap;
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

  /// Where the first navigation goes: the server when it is believed
  /// reachable (today's behaviour), the local pack when it is not and
  /// the pack has this chapter.  The offline decision needs one async
  /// hop (server start + pack lookup), so the WebView is withheld until
  /// it settles -- a blank beat offline beats a dead error page.
  Future<void> _decideInitialUrl() async {
    final localServer = widget.localServer;
    if (localServer == null || ServerStatusManager.isReachable) {
      if (mounted) setState(() => _decidingUrl = false);
      return;
    }
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
        if (item != null && mounted) widget.onTap(item, context);
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

  @override
  void didUpdateWidget(EpubChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Look / furigana / zoom-relevant settings changed: push them down.
    if (oldWidget.look != widget.look) {
      _runJs("window.LuteEpubBridge && window.LuteEpubBridge.setLook('${widget.look}')");
    }
    if (oldWidget.furiganaEnabled != widget.furiganaEnabled) {
      _runJs(
        'window.LuteEpubBridge && window.LuteEpubBridge.setFurigana(${widget.furiganaEnabled})',
      );
    }

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

    // The server's copy loaded: we are online and authenticated, so the
    // pack can grow this chapter and the next one in the background.
    if (url != null && url.host != '127.0.0.1') {
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
    return Stack(
      children: [
        InAppWebView(
          key: ValueKey('epub-webview-${widget.bookId}-${widget.pageNum}'),
          initialUrlRequest: URLRequest(url: WebUri(_pageUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            // Zoom runs through the bridge (the page disables the
            // viewport gesture so double-tap stays a status cycle).
            supportZoom: false,
            transparentBackground: true,
          ),
          onWebViewCreated: _registerHandlers,
          onLoadStop: _onLoadStop,
          onReceivedError: _onReceivedError,
          onReceivedHttpAuthRequest: _onReceivedHttpAuthRequest,
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
