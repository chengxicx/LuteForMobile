/// A single subtitle cue of a YouTube / MP3 / video book.
///
/// The server keeps the book's subtitles in `BkSrtData` as a JSON array of
/// `{"start": secs, "end": secs, "text": str}` (see `lute/models/book.py`,
/// `Book.cues`) and hands it to the player as `LUTE_YT_DATA.cues`.
///
/// [start] / [end] are what decide when a sentence has finished, which is
/// what single-sentence loop and auto-pause act on -- the same boundaries the
/// web player uses (`media-player-base.js`, the `ytCueIndex` check).
class YoutubeCue {
  final double start;
  final double end;
  final String text;

  const YoutubeCue({
    required this.start,
    required this.end,
    required this.text,
  });

  /// Builds a cue from one element of the server's JSON array.
  ///
  /// Returns null for anything unusable (missing/invalid times) rather than
  /// substituting zeroes: a cue with no boundaries would make the player
  /// think every sentence ended immediately, and looping would spin.
  static YoutubeCue? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = _seconds(json['start']);
    final end = _seconds(json['end']);
    if (start == null || end == null) return null;
    return YoutubeCue(
      start: start,
      end: end <= start ? start : end,
      text: (json['text'] as Object?)?.toString() ?? '',
    );
  }

  /// Parses the whole `cues` array, skipping unusable entries.
  static List<YoutubeCue> listFromJson(Object? json) {
    if (json is! List) return const [];
    final cues = <YoutubeCue>[];
    for (final entry in json) {
      final cue = YoutubeCue.fromJson(entry);
      if (cue != null) cues.add(cue);
    }
    return cues;
  }

  static double? _seconds(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  @override
  String toString() =>
      'YoutubeCue(${start.toStringAsFixed(2)}-${end.toStringAsFixed(2)}, '
      '${text.length} chars)';
}

/// YouTube video data parsed from the reading page metadata
/// (the `LUTE_YT_DATA` block rendered by the web player include).
class YoutubeData {
  final String videoId;
  final double startPos;

  /// Subtitle cues (empty for a video with no subtitles loaded).
  final List<YoutubeCue> cues;

  const YoutubeData({
    required this.videoId,
    this.startPos = 0,
    this.cues = const [],
  });

  bool get hasCues => cues.isNotEmpty;
}

/// Bilibili video data parsed from the same `LUTE_YT_DATA` block
/// (`templates/read/bilibili_player.html`).
///
/// The web player does not embed Bilibili's official iframe (it refuses
/// to initialise off the whitelist): it plays the raw DASH stream via
/// dash.js from a manifest the Lute server builds itself
/// (`/read/bilibili/stream/mpd/` with a `bvid`), with every segment
/// relayed by the server.  [mpdUrl] is that server-relative manifest.
/// When the server cannot build it (e.g. Bilibili bans the datacenter IP
/// with HTTP 412) the template renders `mpdUrl = null` and [embedUrl] is
/// the last-resort official embed player -- which plays but offers no
/// playback API, so subtitle sync is unavailable in that mode.
class BilibiliData {
  /// Server-relative on-demand DASH manifest
  /// (`/read/bilibili/stream/mpd/...`); null in embed-only mode.
  final String? mpdUrl;

  /// Absolute URL of Bilibili's official embed player; the fallback.
  final String? embedUrl;

  final double startPos;

  /// Subtitle cues, shared with [YoutubeData] -- the same loop /
  /// auto-pause boundaries drive both players.
  final List<YoutubeCue> cues;

  const BilibiliData({
    this.mpdUrl,
    this.embedUrl,
    this.startPos = 0,
    this.cues = const [],
  });

  bool get hasStream => mpdUrl != null && mpdUrl!.isNotEmpty;
  bool get hasEmbed => embedUrl != null && embedUrl!.isNotEmpty;
  bool get hasCues => cues.isNotEmpty;
}
