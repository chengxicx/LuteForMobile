import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Renders the YouTube video for a `youtube` book, mirroring the web
/// player (see `lute/templates/read/youtube_player.html`).
///
/// The player is created through the YouTube IFrame API inside an
/// [InAppWebView], so it exposes standard YouTube controls.  While the
/// video plays, the current position is polled and reported via
/// [onPositionChanged] so the app can persist it to the server (the web
/// player POSTs to `/read/save_youtube_player_data` on a timer).
class YoutubePlayerView extends StatefulWidget {
  final String videoId;
  final double startPos;
  final int bookId;
  final void Function(int bookId, double position)? onPositionChanged;

  const YoutubePlayerView({
    super.key,
    required this.videoId,
    required this.startPos,
    required this.bookId,
    this.onPositionChanged,
  });

  @override
  State<YoutubePlayerView> createState() => _YoutubePlayerViewState();
}

class _YoutubePlayerViewState extends State<YoutubePlayerView> {
  InAppWebViewController? _controller;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_savePosition()),
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_savePosition());
    super.dispose();
  }

  Future<void> _savePosition() async {
    try {
      final controller = _controller;
      if (controller == null) return;
      final result = await controller.evaluateJavascript(
        source:
            'window.__ytPlayer && typeof window.__ytPlayer.getCurrentTime === "function" ? window.__ytPlayer.getCurrentTime() : null',
      );
      final position = double.tryParse(result?.toString() ?? '');
      if (position != null && position > 0) {
        widget.onPositionChanged?.call(widget.bookId, position);
      }
    } catch (_) {
      // WebView may already be disposed; ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    final html = '''
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
          function onYouTubeIframeAPIReady() {
            window.__ytPlayer = new YT.Player('player', {
              videoId: ${_jsString(widget.videoId)},
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

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.black,
          child: InAppWebView(
            initialData: InAppWebViewInitialData(data: html),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              allowsInlineMediaPlayback: true,
              mediaPlaybackRequiresUserGesture: false,
              transparentBackground: false,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
            },
          ),
        ),
      ),
    );
  }

  String _jsString(String value) {
    return "'${value.replaceAll("'", "\\'")}'";
  }
}
