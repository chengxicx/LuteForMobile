/// Verdict the server's token diff assigned to one word of the sentence.
///
/// Mirrors `lute/read/shadowing.py`: MISS = never spoken, FUZZY = probably
/// misread (a near-match spoken token was paired with it), MATCH = spoken
/// as-is (Japanese compares kana readings, everything else lowercased
/// surface forms).
enum ShadowingTokenStatus { miss, fuzzy, match }

/// One shadowing take, as scored by `POST /read/shadowing/transcribe`.
///
/// [statuses] is parallel to the token list that was uploaded -- index i
/// is the verdict for the i-th token of the sentence.  [spokenForFuzzy]
/// maps the index of a misread token to what whisper actually heard (the
/// server serializes it as a JSON object with string keys).
class ShadowingResult {
  /// Raw whisper transcription of the recording ("Heard" on the web panel).
  final String transcription;

  final List<ShadowingTokenStatus> statuses;

  /// index of a fuzzy (misread) token -> the spoken word heard instead.
  final Map<int, String> spokenForFuzzy;

  /// Spoken tokens that belong to no word of the sentence ("Also heard").
  final List<String> extras;

  /// 0-100: `(matched + 0.5 * fuzzy) / total`, rounded.
  final int score;
  final int matched;
  final int fuzzy;
  final int total;

  /// Length of the recording in seconds, as measured by whisper.
  final double duration;

  /// [total] / [duration] * 60, null when the clip had no measurable
  /// duration.  "morphemes/min" for Japanese, "words/min" otherwise.
  final double? tokensPerMinute;
  final String tokenKind;

  const ShadowingResult({
    required this.transcription,
    required this.statuses,
    required this.spokenForFuzzy,
    required this.extras,
    required this.score,
    required this.matched,
    required this.fuzzy,
    required this.total,
    required this.duration,
    required this.tokensPerMinute,
    required this.tokenKind,
  });

  factory ShadowingResult.fromJson(Map<String, dynamic> json) {
    final statusList = (json['statuses'] as List<dynamic>? ?? const [])
        .map((s) => switch (s) {
              2 => ShadowingTokenStatus.match,
              1 => ShadowingTokenStatus.fuzzy,
              _ => ShadowingTokenStatus.miss,
            })
        .toList();

    final spokenForFuzzy = <int, String>{};
    for (final entry in (json['spoken_for_fuzzy'] as Map<String, dynamic>? ??
            const {}).entries) {
      final index = int.tryParse(entry.key);
      if (index != null && entry.value is String) {
        spokenForFuzzy[index] = entry.value as String;
      }
    }

    return ShadowingResult(
      transcription: json['transcription'] as String? ?? '',
      statuses: statusList,
      spokenForFuzzy: spokenForFuzzy,
      extras: (json['extras'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      score: (json['score'] as num?)?.toInt() ?? 0,
      matched: (json['matched'] as num?)?.toInt() ?? 0,
      fuzzy: (json['fuzzy'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      tokensPerMinute: (json['tokens_per_minute'] as num?)?.toDouble(),
      tokenKind: json['token_kind'] as String? ?? 'word',
    );
  }
}

/// Error categories the shadowing flow maps server/HTTP failures onto, so
/// the panel can show the user what to do next instead of a raw exception.
enum ShadowingErrorKind {
  /// Server responded: whisper is missing (install it in Settings > Whisper).
  whisperMissing,

  /// Server responded 422: the clip contained no recognizable speech.
  noSpeech,

  /// Server responded: transcription or diff blew up, or the network did.
  serverError,

  /// Microphone permission was denied.
  permissionDenied,
}

/// A [ShadowingErrorKind] plus the server's message (for [serverError]) or
/// the raw exception text -- everything the panel's error block needs.
class ShadowingException implements Exception {
  final ShadowingErrorKind kind;
  final String message;

  const ShadowingException(this.kind, this.message);

  @override
  String toString() => message;
}
