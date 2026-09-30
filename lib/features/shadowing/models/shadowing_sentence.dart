/// One shadowing-able sentence of the current reader page.
///
/// The reader screen builds these by grouping the page's [TextItem]s on
/// `sentenceId` -- the mobile equivalent of the web reader's per-sentence
/// word spans (`span.word[data-text]`).  `tokens` feeds the server diff,
/// so it keeps the raw [TextItem.text] (zero-width spaces included; the
/// server's `_clean_token` strips them, same as for the web payload).
class ShadowingSentence {
  final int sentenceId;

  /// The sentence's word tokens, in reading order.
  final List<String> tokens;

  /// Language of the page (from any of the sentence's [TextItem.langId]s);
  /// null when the page carried none -- the server then answers 400.
  final int? languageId;

  /// Rendered text of the sentence (tokens joined, ZWS stripped) -- what
  /// the panel shows big and what TTS reads for text books.
  final String displayText;

  /// Cached book-audio file to clip the reference playback from
  /// (media books only; null for plain text books).
  final String? clipPath;

  /// Cue start / end of the line this sentence sits on, in seconds.
  /// Null together with [clipPath] for books without subtitle cues.
  final double? clipStart;
  final double? clipEnd;

  const ShadowingSentence({
    required this.sentenceId,
    required this.tokens,
    required this.languageId,
    required this.displayText,
    this.clipPath,
    this.clipStart,
    this.clipEnd,
  });

  /// True when the reference is a clip of the book's own audio (as opposed
  /// to a TTS reading of [displayText]).
  bool get hasClip => clipPath != null && clipStart != null && clipEnd != null;
}
