import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/providers/network_providers.dart';
import '../../reader/providers/reader_provider.dart';
import '../models/grammar_point.dart';
import 'grammar_provider.dart';

/// Whether a sentence carries grammar points, as far as the page-level
/// pre-analysis (GrammarNotifier) can tell.
enum GrammarPresence {
  /// The page analysis matched this sentence: the word card's Grammar button
  /// is tappable and the sentence grammar screen opens instantly.
  yes,

  /// The page analysis covered this sentence and matched nothing: the button
  /// is greyed out, so nobody taps into a guaranteed-empty page.
  no,

  /// The page has not been analysed yet, or its analysis failed: keep the
  /// button tappable and let the sentence-level fallback request answer --
  /// a failed analysis proves nothing about any sentence, so never grey out
  /// on top of one.
  unknown,
}

/// One-sentence grammar lookups, layered on top of the page-level analysis.
///
/// The reader pre-analyses the whole page a few seconds after it loads (same
/// request and cache as the Grammar tab). This provider answers the word
/// card's per-sentence questions from that cache when it can, and falls back
/// to a one-sentence request -- the same endpoint with `text: <sentence>` --
/// when the page cache cannot answer (not analysed yet, failed, or the
/// server's sentence splitting does not line up with the reader's).
@immutable
class SentenceGrammarState {
  /// Fallback results, keyed by the sentence text exactly as asked. The
  /// analysis of a sentence depends only on its text, so entries stay valid
  /// across pages.
  final Map<String, List<GrammarPoint>> pointsBySentence;

  const SentenceGrammarState({this.pointsBySentence = const {}});
}

class SentenceGrammarNotifier extends Notifier<SentenceGrammarState> {
  /// Requests in flight, keyed by sentence text, so re-opening the same
  /// sentence shares the first request instead of starting a second one.
  final Map<String, Future<List<GrammarPoint>>> _inFlight = {};

  /// Last failure per sentence. A sentence that just failed (offline, server
  /// error) is not re-requested until the cooldown passes; the screen shows
  /// the stored error instead of hammering the server on every reopen.
  static const Duration _cooldown = Duration(seconds: 30);
  final Map<String, (DateTime, Object)> _lastFailure = {};

  @override
  SentenceGrammarState build() {
    return const SentenceGrammarState();
  }

  /// Grammar points for one sentence: the per-sentence cache, then the page
  /// pre-analysis, then a one-sentence request.
  ///
  /// [force] bypasses the failure cooldown (the error screen's Retry).
  Future<List<GrammarPoint>> getSentenceGrammar(
    String sentenceText, {
    bool force = false,
  }) {
    final cached = state.pointsBySentence[sentenceText];
    if (cached != null) return Future.value(cached);

    final inFlight = _inFlight[sentenceText];
    if (inFlight != null) return inFlight;

    // The page pre-analysis knows this sentence: instant, no request. Checked
    // before the cooldown so an analysis that landed while the sentence was
    // cooling down still answers instantly.  An empty answer from a *valid*
    // page analysis still falls through to the request -- that path is only
    // reachable when the greyed-out button was bypassed, and the request is
    // the authority on "really nothing".
    final pagePoints = pointsFromPageCache(sentenceText);
    if (pagePoints != null && pagePoints.isNotEmpty) {
      _cache(sentenceText, pagePoints);
      return Future.value(pagePoints);
    }

    final failure = _lastFailure[sentenceText];
    if (failure != null &&
        !force &&
        DateTime.now().difference(failure.$1) < _cooldown) {
      return Future.error(failure.$2);
    }

    final request = _requestSentence(sentenceText);
    _inFlight[sentenceText] = request;
    return request;
  }

  /// Whether [sentenceText] carries grammar points, for the word card's
  /// Grammar button state. See [GrammarPresence] for the three answers.
  GrammarPresence presenceFor(String sentenceText) {
    final page = ref.read(readerProvider).pageData;
    if (page == null) return GrammarPresence.unknown;

    final grammar = ref.read(grammarProvider);
    // Not the current page's analysis (not run yet, or the reader has since
    // turned the page): unknown, not no.
    if (grammar.analyzedKey != '${page.bookId}/${page.currentPage}') {
      return GrammarPresence.unknown;
    }
    if (grammar.isLoading || grammar.errorMessage != null) {
      return GrammarPresence.unknown;
    }

    final points = pointsForPage(pagePoints: grammar.points, sentenceText: sentenceText);
    return points.isEmpty ? GrammarPresence.no : GrammarPresence.yes;
  }

  /// What the page pre-analysis says about [sentenceText]: the matching
  /// points, or null when the page cache cannot answer (no page, analysis
  /// missing, still loading, or failed).
  List<GrammarPoint>? pointsFromPageCache(String sentenceText) {
    final page = ref.read(readerProvider).pageData;
    if (page == null) return null;

    final grammar = ref.read(grammarProvider);
    if (grammar.analyzedKey != '${page.bookId}/${page.currentPage}') return null;
    if (grammar.isLoading || grammar.errorMessage != null) return null;

    return pointsForPage(pagePoints: grammar.points, sentenceText: sentenceText);
  }

  Future<List<GrammarPoint>> _requestSentence(String sentenceText) async {
    try {
      final page = ref.read(readerProvider).pageData;
      if (page == null) return const [];

      final points = await grammarRequestLock.run(
        () => ref.read(sentenceGrammarFetchProvider)(
              page.bookId,
              page.currentPage,
              sentenceText,
            ),
      );

      _cache(sentenceText, points);
      return points;
    } catch (e, stackTrace) {
      ApiLogger.logError(
        'sentenceGrammar.request',
        e,
        stackTrace: stackTrace,
        details: 'sentence=$sentenceText',
      );
      _lastFailure[sentenceText] = (DateTime.now(), e);
      rethrow;
    } finally {
      _inFlight.remove(sentenceText);
    }
  }

  void _cache(String sentenceText, List<GrammarPoint> points) {
    _lastFailure.remove(sentenceText);
    state = SentenceGrammarState(
      pointsBySentence: {
        ...state.pointsBySentence,
        sentenceText: points,
      },
    );
  }

  /// The page-analysis points that touch [sentenceText].
  ///
  /// The server splits the page text with its own logic, so the sentence the
  /// reader tapped can come back merged with a neighbour (subtitle lines
  /// without ending punctuation) or split in two. Matching is therefore
  /// "equal, or one contains the other", which survives both mistakes; the
  /// worst case of a leftover mismatch is a still-tappable button, never a
  /// wrongly greyed-out one.
  static List<GrammarPoint> pointsForPage({
    required List<GrammarPoint> pagePoints,
    required String sentenceText,
  }) {
    final needle = _normalize(sentenceText);
    if (needle.isEmpty) return const [];

    return pagePoints.where((point) {
      return point.examples.any((example) {
        final hay = _normalize(example.sentence);
        if (hay.isEmpty) return false;
        return hay == needle || hay.contains(needle) || needle.contains(hay);
      });
    }).toList();
  }

  /// Whitespace-free comparison text: the server's example sentences and the
  /// reader's token-joined sentences disagree about spacing on non-CJK
  /// languages, and the spaces never decide whether a grammar point applies.
  ///
  /// Zero-width characters are stripped too: Lute's page text carries U+200B
  /// inside words (furigana boundaries -- かけま\u200bした), and those flow
  /// into the server's example sentences while the reader's token-joined
  /// sentence has none.  Without this, no example ever equals the tapped
  /// sentence and every Grammar button on a real book greys out.
  static final RegExp _invisibleChars = RegExp(
    r'[\u200b-\u200f\u2060-\u2064\ufeff\s]+',
  );

  static String _normalize(String text) => text.replaceAll(_invisibleChars, '');
}

/// The one-sentence analysis request, as a function so tests can fake the
/// endpoint without touching Hive-backed services.
typedef SentenceGrammarFetch =
    Future<List<GrammarPoint>> Function(int bookId, int pageNum, String text);

final sentenceGrammarFetchProvider = Provider<SentenceGrammarFetch>((ref) {
  return (bookId, pageNum, text) => ref
      .read(contentServiceProvider)
      .getGrammarAnalysis(bookId: bookId, pageNum: pageNum, text: text);
});

final sentenceGrammarProvider =
    NotifierProvider<SentenceGrammarNotifier, SentenceGrammarState>(() {
      return SentenceGrammarNotifier();
    });
