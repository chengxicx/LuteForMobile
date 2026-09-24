import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/network/session_manager.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/youtube_data.dart';

/// Renders the online video for a `youtube` *or* `bilibili` book with the
/// reader's own control bar, mirroring the web player (`youtube_player.html`
/// / `bilibili_player.html` + `media-player-base.js`).
///
/// For a YouTube book the video runs through the YouTube IFrame API inside
/// an [InAppWebView], because that is the only way to play a YouTube video
/// in an app.  For a Bilibili book the WebView renders an HTML5 `<video>`
/// driven by dash.js from the Lute server's own DASH relay
/// (`/read/bilibili/stream/...`), exactly like the web player: Bilibili's
/// official iframe refuses to initialise off its domain whitelist and
/// exposes no playback API anyway.  Everything above it -- prev/next
/// sentence, play/pause, timeline, rate, Loop and Auto-pause -- is drawn by
/// Flutter and drives the backend through the same small JS bridge
/// (`window.__ytApi`), so the feature set matches the web player.
///
/// Sentences come from the book's subtitle cues ([YoutubeCue]).  The web
/// player decides "this sentence is finished" by comparing the playhead with
/// `cue.end`, and Loop / Auto-pause act on that; the same comparison happens
/// here, on a 250 ms poll -- the same cadence the web player uses.
class YoutubePlayerView extends StatefulWidget {
  /// YouTube video id; null for a Bilibili book.
  final String? videoId;
  final double startPos;
  final int bookId;

  /// Subtitle cues for the book, in playback order.  Empty for a video with
  /// no subtitles: playback still works, but per-sentence loop and auto-pause
  /// have nothing to act on and are disabled.
  final List<YoutubeCue> cues;

  /// Set for a `bilibili` book.  When non-null the WebView plays the
  /// server-relayed DASH stream (dash.js) instead of the YouTube iframe;
  /// [serverUrl] is then required so the stream URLs resolve and the
  /// WebView can answer the server's Basic Auth challenge.
  final BilibiliData? bilibili;

  /// Base URL of the configured Lute server (e.g.
  /// `https://www.metaman.dpdns.org`).  Only used by the Bilibili backend.
  final String? serverUrl;

  final void Function(int bookId, double position)? onPositionChanged;

  /// Called when the cue the playhead is on changes, with its index in
  /// [cues] -- or -1 when the playhead is not inside any cue (before the
  /// first subtitle, or in a gap between two).
  ///
  /// The reading page uses it to mark the line being played in the page text
  /// itself (the web player's `ytMarkPlayingLine`).  A cue that is not on the
  /// page being read is the caller's problem: it resolves the index against
  /// its own lines and marks nothing.
  final void Function(int cueIndex)? onActiveCueChanged;

  const YoutubePlayerView({
    super.key,
    this.videoId,
    required this.startPos,
    required this.bookId,
    this.cues = const [],
    this.bilibili,
    this.serverUrl,
    this.onPositionChanged,
    this.onActiveCueChanged,
  });

  @override
  State<YoutubePlayerView> createState() => _YoutubePlayerViewState();
}

/// One reading of the iframe's state, as delivered by the JS bridge.
class _YtSnapshot {
  final double time;
  final double duration;

  /// Raw YouTube player state: -1 unstarted, 0 ended, 1 playing,
  /// 2 paused, 3 buffering, 5 cued.
  final int state;

  const _YtSnapshot({
    required this.time,
    required this.duration,
    required this.state,
  });

  static const int playing = 1;

  bool get isPlaying => state == playing;

  /// Position + duration + state, `|`-separated.
  ///
  /// A plain delimited string rather than JSON on purpose: the value comes
  /// back from `evaluateJavascript` as a platform-dependent marshalling of the
  /// JS value, and a bare string of digits is the one shape that survives
  /// both WebView engines unchanged.
  static _YtSnapshot? parse(String raw) {
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final time = double.tryParse(parts[0]);
    if (time == null) return null;
    return _YtSnapshot(
      time: time,
      duration: double.tryParse(parts[1]) ?? 0,
      state: int.tryParse(parts[2]) ?? -1,
    );
  }

  _YtSnapshot copyWith({
    double? time,
    double? duration,
    int? state,
  }) {
    return _YtSnapshot(
      time: time ?? this.time,
      duration: duration ?? this.duration,
      state: state ?? this.state,
    );
  }
}

class _YoutubePlayerViewState extends State<YoutubePlayerView> {
  /// Poll cadence, matching the web player's `setInterval(ytPoll, 250)`.
  static const Duration _pollInterval = Duration(milliseconds: 250);

  /// How often the position is persisted, matching the previous behaviour of
  /// this view (the web player uses 15s; the mobile save endpoint is cheap).
  static const Duration _saveInterval = Duration(seconds: 5);

  /// Rate range and step, matching the web player's − / + control.
  static const double _minRate = 0.25;
  static const double _maxRate = 2.0;
  static const double _rateStep = 0.25;

  InAppWebViewController? _controller;
  Timer? _pollTimer;
  double _lastSavedTime = 0;

  /// The cue the playhead was last seen on.  Loop / auto-pause are checked
  /// against *this* cue's end: once the time has moved past it, a fresh
  /// lookup already reports the next cue, so checking that one would never
  /// fire.  Same ordering trap the web player documents.
  int _activeCueIndex = -1;

  /// After a loop/auto-pause seek, ignore boundary checks briefly.  The seek
  /// is asynchronous, so the next poll can still read the pre-seek time and
  /// would otherwise fire the boundary again.
  DateTime? _ignoreBoundaryUntil;

  bool _isDragging = false;
  double? _dragSeconds;

  bool _loop = false;
  bool _autoPause = false;
  double _rate = 1.0;

  /// Drives the control bar only.  Kept separate from `setState` so the 250 ms
  /// poll does not rebuild the [InAppWebView] four times a second.
  final ValueNotifier<_YtSnapshot?> _snapshot = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // Read the last known position before the notifier goes away.
    unawaited(_savePosition());
    _snapshot.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // JS bridge
  // -------------------------------------------------------------------------

  Future<String?> _eval(String source) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final result = await controller.evaluateJavascript(source: source);
      return result?.toString();
    } catch (_) {
      // The WebView may already be gone (page turn, route pop).
      return null;
    }
  }

  Future<void> _play() => _eval('window.__ytApi && window.__ytApi.play()');

  Future<void> _pause() => _eval('window.__ytApi && window.__ytApi.pause()');

  Future<void> _seekPlayer(double seconds) => _eval(
    'window.__ytApi && window.__ytApi.seekTo(${seconds.toStringAsFixed(3)})',
  );

  Future<void> _setPlayerRate(double rate) => _eval(
    'window.__ytApi && window.__ytApi.setRate(${rate.toStringAsFixed(2)})',
  );

  Future<_YtSnapshot?> _readSnapshot() async {
    final raw = await _eval(
      "window.__ytApi ? window.__ytApi.snapshot() : ''",
    );
    if (raw == null || raw.isEmpty) return null;
    return _YtSnapshot.parse(raw);
  }

  // -------------------------------------------------------------------------
  // Poll loop: playhead, cue tracking, loop / auto-pause
  // -------------------------------------------------------------------------

  Future<void> _poll() async {
    final snap = await _readSnapshot();
    if (snap == null || !mounted) return;

    // Single-sentence loop / auto-pause.
    //
    // Loop beats auto-pause when both are on: the sentence repeats rather
    // than stopping.  On auto-pause the media rewinds to the sentence start
    // and stops there, so pressing play reads the same sentence again --
    // identical to the web player.
    final guardActive =
        _ignoreBoundaryUntil != null &&
        DateTime.now().isBefore(_ignoreBoundaryUntil!);

    if (snap.isPlaying && !guardActive && _hasActiveCue) {
      final cue = widget.cues[_activeCueIndex];
      if (cue.end > cue.start && snap.time >= cue.end) {
        if (_loop) {
          await _rewindTo(cue.start, keepPlaying: true);
          _publish(snap.copyWith(time: cue.start));
          return;
        }
        if (_autoPause) {
          await _rewindTo(cue.start, keepPlaying: false);
          _publish(snap.copyWith(time: cue.start, state: 2));
          return;
        }
      }
    }

    _setActiveCue(_cueIndexAt(snap.time));
    _publish(snap);
    _maybeSavePosition(snap.time);
  }

  /// Records the cue the playhead is on, telling the reading page about it
  /// when it changes.  One setter because [_activeCueIndex] is written from
  /// the poll, from a sentence jump and from a scrub, and all three owe the
  /// page the same notification.
  void _setActiveCue(int index) {
    if (index == _activeCueIndex) return;
    _activeCueIndex = index;
    widget.onActiveCueChanged?.call(index);
  }

  /// Seeks back to [seconds] and either keeps playing or pauses there.
  Future<void> _rewindTo(double seconds, {required bool keepPlaying}) async {
    _ignoreBoundaryUntil = DateTime.now().add(const Duration(seconds: 1));
    await _seekPlayer(seconds);
    if (keepPlaying) {
      await _play();
    } else {
      await _pause();
    }
  }

  void _publish(_YtSnapshot snap) {
    if (!mounted) return;
    _snapshot.value = snap;
  }

  void _maybeSavePosition(double time) {
    if (time - _lastSavedTime < _saveInterval.inSeconds) return;
    _lastSavedTime = time;
    widget.onPositionChanged?.call(widget.bookId, time);
  }

  Future<void> _savePosition() async {
    final time = _snapshot.value?.time ?? 0;
    if (time <= 0) return;
    widget.onPositionChanged?.call(widget.bookId, time);
  }

  bool get _hasActiveCue =>
      _activeCueIndex >= 0 && _activeCueIndex < widget.cues.length;

  /// Index of the cue covering [time], or -1 when the time falls outside
  /// every cue (before the first subtitle, or in a gap between two).
  int _cueIndexAt(double time) {
    for (var i = 0; i < widget.cues.length; i++) {
      final cue = widget.cues[i];
      if (time >= cue.start && time < cue.end) return i;
    }
    return -1;
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  Future<void> _togglePlay() async {
    final snap = _snapshot.value;
    if (snap == null) return;
    if (snap.isPlaying) {
      await _pause();
    } else {
      await _play();
    }
  }

  /// Prev/next sentence.
  ///
  /// Web configures this player with `jumpCueAutoplay: "autopause"`: while
  /// auto-pause is on (line-by-line study) stepping plays the sentence right
  /// away; otherwise the play state is kept, so the user can scrub through
  /// subtitles without forcing playback.
  Future<void> _jumpCue(int delta) async {
    if (widget.cues.isEmpty) return;

    var target = _activeCueIndex < 0 ? 0 : _activeCueIndex + delta;
    if (target < 0) target = 0;
    if (target >= widget.cues.length) target = widget.cues.length - 1;

    final cue = widget.cues[target];
    _setActiveCue(target);
    _ignoreBoundaryUntil = DateTime.now().add(const Duration(seconds: 1));
    await _seekPlayer(cue.start);

    if (_autoPause) await _play();
  }

  Future<void> _seekToTime(double seconds) async {
    _setActiveCue(_cueIndexAt(seconds));
    await _seekPlayer(seconds);
  }

  Future<void> _setRate(double rate) async {
    final clamped = rate.clamp(_minRate, _maxRate).toDouble();
    if (clamped == _rate) return;
    setState(() => _rate = clamped);
    await _setPlayerRate(clamped);
  }

  Future<void> _toggleLoop() async {
    final next = !_loop;
    setState(() => _loop = next);

    // "Press loop to keep looping": turning loop on while the player is
    // paused -- typically auto-paused at the end of a sentence -- starts the
    // loop immediately rather than waiting for another press of play.
    // Turning it off never pauses.
    if (next && !(_snapshot.value?.isPlaying ?? false)) {
      await _play();
    }
  }

  void _toggleAutoPause() {
    setState(() => _autoPause = !_autoPause);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: InAppWebView(
                // Both backends are loaded in onWebViewCreated instead of
                // through initialData: the multi-user session cookie must
                // be installed first, and the page needs the server as its
                // base URL.  For Bilibili that makes the relative dash.js
                // include / DASH manifest same-origin; for YouTube it gives
                // the IFrame API a real https origin -- with loadData's
                // default null/"about:blank" origin YouTube refuses the
                // embedded player with error 153 ("player misconfigured").
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  allowsInlineMediaPlayback: true,
                  mediaPlaybackRequiresUserGesture: false,
                  transparentBackground: false,
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  unawaited(_loadPlayerPage(controller));
                },
                onReceivedHttpAuthRequest: _onReceivedHttpAuthRequest,
                onLoadStop: (controller, url) {
                  // Restore a rate the user picked before a reload, so the
                  // iframe does not silently drop back to 1x.
                  if (_rate != 1.0) unawaited(_setPlayerRate(_rate));
                },
              ),
            ),
          ),
        ),
        ValueListenableBuilder<_YtSnapshot?>(
          valueListenable: _snapshot,
          builder: (context, snap, _) => _buildControlBar(context, snap),
        ),
      ],
    );
  }

  Widget _buildControlBar(BuildContext context, _YtSnapshot? snap) {
    final duration = snap?.duration ?? 0;
    final position = snap?.time ?? 0;
    final maxDuration = duration > 0 ? duration : 1.0;
    final hasCues = widget.cues.isNotEmpty;
    final canGoPrevious = hasCues && _activeCueIndex > 0;
    final canGoNext =
        hasCues && _activeCueIndex >= 0 && _activeCueIndex < widget.cues.length - 1;

    double sliderValue = _isDragging
        ? (_dragSeconds ?? position)
        : position;
    if (sliderValue > maxDuration) sliderValue = maxDuration;
    if (sliderValue < 0) sliderValue = 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4.0,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
          ),
          child: Slider(
            value: sliderValue,
            min: 0.0,
            max: maxDuration,
            onChanged: (value) {
              setState(() {
                _isDragging = true;
                _dragSeconds = value;
              });
            },
            onChangeEnd: (value) {
              setState(() {
                _isDragging = false;
                _dragSeconds = null;
              });
              unawaited(_seekToTime(value));
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.navigate_before),
              onPressed: canGoPrevious ? () => unawaited(_jumpCue(-1)) : null,
              color: context.audioPlayerIcon,
              iconSize: 22,
              padding: const EdgeInsets.all(4),
              tooltip: 'Previous sentence',
            ),
            IconButton(
              icon: Icon(
                (snap?.isPlaying ?? false)
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              onPressed: snap == null ? null : () => unawaited(_togglePlay()),
              color: context.audioPlayerIcon,
              iconSize: 32,
              tooltip: 'Play / pause',
            ),
            IconButton(
              icon: const Icon(Icons.navigate_next),
              onPressed: canGoNext ? () => unawaited(_jumpCue(1)) : null,
              color: context.audioPlayerIcon,
              iconSize: 22,
              padding: const EdgeInsets.all(4),
              tooltip: 'Next sentence',
            ),
            const SizedBox(width: 4),
            _buildTimeDisplay(context, position, duration),
            _buildRateControl(context),
            _buildToggle(
              context,
              icon: _loop ? Icons.repeat_on : Icons.repeat,
              isOn: _loop,
              // Without cues there is no sentence to repeat, so the toggle
              // would be a switch with nothing behind it.
              tooltip: !hasCues
                  ? 'Loop sentence (no subtitles for this video)'
                  : _loop
                  ? 'Loop current sentence: on'
                  : 'Loop current sentence: off',
              onPressed: hasCues ? () => unawaited(_toggleLoop()) : null,
            ),
            _buildToggle(
              context,
              icon: _autoPause
                  ? Icons.pause_circle
                  : Icons.pause_circle_outline,
              isOn: _autoPause,
              tooltip: !hasCues
                  ? 'Auto-pause at each sentence (no subtitles for this video)'
                  : _autoPause
                  ? 'Auto-pause at each sentence: on'
                  : 'Auto-pause at each sentence: off',
              onPressed: hasCues ? _toggleAutoPause : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimeDisplay(
    BuildContext context,
    double position,
    double duration,
  ) {
    return Text(
      '${_formatSeconds(position)} / ${_formatSeconds(duration)}',
      style: TextStyle(
        color: context.audioPlayerIcon,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  /// − / + rate control with the current value between them.  Tapping the
  /// value resets to 1x, matching the web player's rate indicator.
  Widget _buildRateControl(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: () => unawaited(_setRate(_rate - _rateStep)),
          color: context.audioPlayerIcon,
          iconSize: 18,
          padding: const EdgeInsets.all(4),
          visualDensity: VisualDensity.compact,
          tooltip: 'Slower',
        ),
        GestureDetector(
          onTap: () => unawaited(_setRate(1.0)),
          child: Container(
            constraints: const BoxConstraints(minWidth: 34),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Text(
              _formatRate(_rate),
              style: TextStyle(
                color: context.audioPlayerIcon,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => unawaited(_setRate(_rate + _rateStep)),
          color: context.audioPlayerIcon,
          iconSize: 18,
          padding: const EdgeInsets.all(4),
          visualDensity: VisualDensity.compact,
          tooltip: 'Faster',
        ),
      ],
    );
  }

  Widget _buildToggle(
    BuildContext context, {
    required IconData icon,
    required bool isOn,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      onPressed: onPressed,
      color: isOn ? context.audioBookmark : context.audioPlayerIcon,
      disabledColor: context.audioPlayerIcon.withValues(alpha: 0.35),
      iconSize: 22,
      padding: const EdgeInsets.all(4),
      tooltip: tooltip,
    );
  }

  String _formatRate(double rate) {
    final text = rate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
    return '${text.isEmpty ? '1' : text}x';
  }

  String _formatSeconds(double seconds) {
    if (!seconds.isFinite || seconds < 0) seconds = 0;
    final total = seconds.floor();
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final secs = total % 60;
    return hours > 0
        ? '$hours:${two(minutes)}:${two(secs)}'
        : '${two(minutes)}:${two(secs)}';
  }

  /// Quotes [value] as a single-quoted JS string literal.
  String _jsString(String value) {
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
    return "'$escaped'";
  }

  bool get _isBilibili => widget.bilibili != null;

  String _buildHtml() =>
      _isBilibili ? _buildBilibiliHtml() : _buildYoutubeHtml();

  /// Loads the player HTML through [InAppWebViewController.loadData].
  ///
  /// When a server URL is configured (the normal case, including the
  /// termux loopback) the page gets the server's origin as its base URL:
  ///   * the multi-user `session` cookie (when logged in) is installed via
  ///     CookieManager first, since `/read/bilibili/stream/...` requires
  ///     login in multi-user mode and an unauthenticated XHR is redirected
  ///     to `/login`, which dash.js cannot parse as a manifest;
  ///   * Bilibili's relative `/static/vendor/dash.all.min.js` include and
  ///     server-relative manifest URL then resolve same-origin (no CORS
  ///     headers needed);
  ///   * the YouTube IFrame API reports a real https origin, without which
  ///     YouTube rejects the embedded player (player error 153).
  ///
  /// Basic Auth is not handled here: it is answered through
  /// [_onReceivedHttpAuthRequest] when the proxy challenges the request.
  Future<void> _loadPlayerPage(InAppWebViewController controller) async {
    final serverUrl = widget.serverUrl;
    if (serverUrl != null && serverUrl.isNotEmpty) {
      final cookie = SessionManager.sessionCookie;
      if (cookie != null) {
        final equals = cookie.indexOf('=');
        if (equals > 0) {
          try {
            await CookieManager.instance().setCookie(
              url: WebUri(serverUrl),
              name: cookie.substring(0, equals),
              value: cookie.substring(equals + 1),
              path: '/',
            );
          } catch (_) {
            // A missing cookie only matters in multi-user mode; the load
            // below still proceeds.
          }
        }
      }
    }

    try {
      await controller.loadData(
        data: _buildHtml(),
        baseUrl: serverUrl == null || serverUrl.isEmpty
            ? null
            : WebUri(serverUrl),
      );
    } catch (_) {
      // The WebView may be gone already (page turn, route pop).
    }
  }

  /// Answers the proxy Basic Auth challenge for the Lute server with the
  /// stored credentials.  Challenges from any other host (e.g. the Bilibili
  /// embed iframe) are cancelled, so the credentials never leave the
  /// configured server.
  Future<HttpAuthResponse?> _onReceivedHttpAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  ) async {
    final serverUrl = widget.serverUrl;
    final serverHost =
        serverUrl == null ? '' : Uri.tryParse(serverUrl)?.host ?? '';
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

  String _buildYoutubeHtml() {
    return '''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
          #player { width: 100vw; height: 100vh; }
        </style>
      </head>
      <body>
        <div id="player"></div>
        <script>
          var tag = document.createElement('script');
          tag.src = 'https://www.youtube.com/iframe_api';
          var first = document.getElementsByTagName('script')[0];
          first.parentNode.insertBefore(tag, first);
          window.__ytPlayer = null;

          // Bridge used by the Flutter control bar.  Every method resolves
          // window.__ytPlayer at call time: the iframe API loads
          // asynchronously, so a captured reference would be null.
          window.__ytApi = {
            play: function () {
              var p = window.__ytPlayer;
              if (p && typeof p.playVideo === 'function') p.playVideo();
            },
            pause: function () {
              var p = window.__ytPlayer;
              if (p && typeof p.pauseVideo === 'function') p.pauseVideo();
            },
            seekTo: function (seconds) {
              var p = window.__ytPlayer;
              if (p && typeof p.seekTo === 'function') p.seekTo(seconds, true);
            },
            setRate: function (rate) {
              var p = window.__ytPlayer;
              if (p && typeof p.setPlaybackRate === 'function')
                p.setPlaybackRate(rate);
            },
            // "time|duration|state".  A delimited string rather than JSON:
            // this value crosses the WebView bridge and a string of digits
            // is the one shape both engines hand back unchanged.
            snapshot: function () {
              var p = window.__ytPlayer;
              if (!p || typeof p.getCurrentTime !== 'function') return '';
              var t = p.getCurrentTime();
              if (typeof t !== 'number' || !isFinite(t)) t = 0;
              var d = p.getDuration();
              if (typeof d !== 'number' || !isFinite(d)) d = 0;
              var s = p.getPlayerState();
              if (typeof s !== 'number') s = -1;
              return t + '|' + d + '|' + s;
            }
          };

          function onYouTubeIframeAPIReady() {
            window.__ytPlayer = new YT.Player('player', {
              videoId: ${_jsString(widget.videoId!)},
              playerVars: {
                start: ${widget.startPos.round()},
                playsinline: 1,
                rel: 0,
                modestbranding: 1
              }
            });
          }
        </script>
      </body>
      </html>
    ''';
  }

  /// The Bilibili page: an HTML5 `<video>` driven by dash.js from the
  /// server's own DASH relay, mirroring `bilibili-player.js`.
  ///
  /// The bridge exposes the same `window.__ytApi` surface as the YouTube
  /// page, so the Flutter poll loop and control bar work unchanged.  If the
  /// manifest cannot be played (no relay for this server, dash.js failed to
  /// load, stream error) the page swaps in Bilibili's official embed
  /// iframe -- the same last-resort fallback as the web player.  That
  /// player has no external API, so `snapshot()` returns '' in embed mode
  /// and the Flutter transport controls stay inert, exactly like the web
  /// player disabling its controls in that mode.
  String _buildBilibiliHtml() {
    final bili = widget.bilibili!;
    final mpdLiteral =
        bili.hasStream ? _jsString(bili.mpdUrl!) : "''";
    final embedLiteral =
        bili.hasEmbed ? _jsString(bili.embedUrl!) : "''";
    return '''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
          #bili-player { width: 100vw; height: 100vh; object-fit: contain; background: #000; }
          #bili-embed { width: 100vw; height: 100vh; border: 0; display: none; }
        </style>
      </head>
      <body>
        <video id="bili-player" playsinline></video>
        <iframe id="bili-embed" allowfullscreen="true" scrolling="no" frameborder="0"></iframe>
        <script src="/static/vendor/dash.all.min.js"></script>
        <script>
          var MPD_URL = $mpdLiteral;
          var EMBED_URL = $embedLiteral;
          var START_POS = ${widget.startPos.toStringAsFixed(3)};
          var v = document.getElementById('bili-player');
          var embedMode = false;

          // Same bridge contract as the YouTube page: play / pause /
          // seekTo / setRate / "time|duration|state".
          window.__ytApi = {
            play: function () {
              if (embedMode) return;
              var p = v.play();
              if (p && typeof p.catch === 'function') p.catch(function () {});
            },
            pause: function () { if (!embedMode) v.pause(); },
            seekTo: function (seconds) {
              if (embedMode) return;
              try { v.currentTime = seconds; } catch (e) { /* ignore */ }
            },
            setRate: function (rate) { if (!embedMode) v.playbackRate = rate; },
            snapshot: function () {
              if (embedMode) return '';
              var t = v.currentTime;
              if (typeof t !== 'number' || !isFinite(t)) t = 0;
              var d = v.duration;
              if (typeof d !== 'number' || !isFinite(d)) d = 0;
              var s = v.ended ? 0 : (v.paused ? 2 : 1);
              return t + '|' + d + '|' + s;
            }
          };

          // Last-resort fallback, mirroring ytUseEmbedPlayer() in
          // bilibili-player.js.  Bilibili's own player owns playback; the
          // snapshot goes empty so the Flutter controls disable.
          function useEmbed() {
            if (embedMode || !EMBED_URL) return;
            embedMode = true;
            v.style.display = 'none';
            var f = document.getElementById('bili-embed');
            f.src = EMBED_URL;
            f.style.display = 'block';
          }

          v.addEventListener('loadedmetadata', function () {
            if (START_POS > 0 && isFinite(v.duration)) {
              try { v.currentTime = START_POS; } catch (e) { /* ignore */ }
            }
          });

          (function init() {
            if (!MPD_URL) { useEmbed(); return; }
            if (typeof dashjs === 'undefined' ||
                typeof dashjs.MediaPlayer === 'undefined') {
              useEmbed();
              return;
            }
            try {
              var dp = dashjs.MediaPlayer().create();
              // Start on (and stay on) the cheapest rendition: the stream
              // is relayed through a narrow egress, so ABR climbing of its
              // own accord is exactly wrong.  Same settings as the web
              // player's LuteBilibiliPlayer.
              try {
                dp.updateSettings({
                  streaming: {
                    abr: {
                      autoSwitchBitrate: { video: false },
                      initialBitrate: { video: 1 }
                    }
                  }
                });
              } catch (e) { /* another dash.js version: default holds */ }
              dp.on('error', useEmbed);
              dp.initialize(v, MPD_URL, false);
            } catch (e) {
              useEmbed();
            }
          })();
        </script>
      </body>
      </html>
    ''';
  }
}
