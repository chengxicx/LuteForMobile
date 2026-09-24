import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/providers/network_providers.dart';
import '../../reader/models/page_data.dart';
import '../../reader/providers/reader_provider.dart';
import '../models/grammar_point.dart';

/// Grammar points for the page the reader is currently showing.
///
/// The analysis is done server-side (`/read/grammar_analysis`), on the page
/// text the reader sends, exactly like the web reader's "Analyze grammar".
@immutable
class GrammarState {
  final bool isLoading;
  final String? errorMessage;
  final List<GrammarPoint> points;

  /// `<bookId>/<pageNum>` of the page [points] belong to, so a page turn can
  /// be told apart from a re-render.
  final String? analyzedKey;
  final int? bookId;
  final int? pageNum;
  final String? bookTitle;

  /// False when no book is loaded at all -- distinct from "analysed, found
  /// nothing", which is a real answer worth showing.
  final bool hasBook;

  const GrammarState({
    this.isLoading = false,
    this.errorMessage,
    this.points = const [],
    this.analyzedKey,
    this.bookId,
    this.pageNum,
    this.bookTitle,
    this.hasBook = true,
  });

  bool get hasResults => points.isNotEmpty;
}

class GrammarNotifier extends Notifier<GrammarState> {
  /// `<bookId>/<pageNum>` of the request currently in flight, so a rebuild
  /// cannot start a second one for the same page.
  String? _inFlightKey;

  @override
  GrammarState build() {
    return const GrammarState();
  }

  /// Analyse whatever page the reader has loaded.
  ///
  /// [force] re-runs the request for the same page (the refresh button); a
  /// page turn re-runs it by itself, because the key no longer matches.
  Future<void> analyzeCurrentPage({bool force = false}) async {
    final page = ref.read(readerProvider).pageData;

    if (page == null) {
      state = const GrammarState(hasBook: false);
      return;
    }

    final key = '${page.bookId}/${page.currentPage}';

    // One request per page at a time.  The screen analyses from `build`, and
    // while a request is in flight `analyzedKey` still holds the previous
    // value, so without this guard every rebuild would start another request.
    // That is not just wasteful: the server's Japanese analyser shares a
    // single global tokenizer, and two overlapping calls raise
    // "RuntimeError: Already borrowed" and a 500.  Set before the first
    // `await`, so the guard is synchronous.
    if (_inFlightKey == key) return;

    if (!force && state.analyzedKey == key) {
      return;
    }

    // Keep the results on screen while re-analysing the same page (the refresh
    // button); drop them when the page changed, because the old page's grammar
    // points have nothing to do with the new one.
    final samePage = state.analyzedKey == key;

    state = GrammarState(
      isLoading: true,
      points: samePage ? state.points : const [],
      analyzedKey: state.analyzedKey,
      bookId: page.bookId,
      pageNum: page.currentPage,
      bookTitle: page.title,
    );

    _inFlightKey = key;
    try {
      final points = await ref
          .read(contentServiceProvider)
          .getGrammarAnalysis(
            bookId: page.bookId,
            pageNum: page.currentPage,
            text: pageText(page),
          );

      state = GrammarState(
        points: points,
        analyzedKey: key,
        bookId: page.bookId,
        pageNum: page.currentPage,
        bookTitle: page.title,
      );
    } catch (e, stackTrace) {
      ApiLogger.logError('grammar.analyzeCurrentPage', e, stackTrace: stackTrace);
      state = GrammarState(
        errorMessage: e.toString(),
        analyzedKey: key,
        bookId: page.bookId,
        pageNum: page.currentPage,
        bookTitle: page.title,
      );
    } finally {
      _inFlightKey = null;
    }
  }

  /// The page text as the analysers expect it: one paragraph per line.
  ///
  /// Paragraphs are joined with newlines rather than spaces so subtitle and
  /// transcript lines (which usually carry no sentence-ending punctuation)
  /// stay separable on the server instead of collapsing into one long
  /// pseudo-sentence.  Same rule as the web reader's `open_grammar_analysis`.
  static String pageText(PageData page) {
    final buffer = StringBuffer();
    for (final paragraph in page.paragraphs) {
      final text = paragraph.fullText.trim();
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(text);
    }
    return buffer.toString();
  }
}

final grammarProvider = NotifierProvider<GrammarNotifier, GrammarState>(() {
  return GrammarNotifier();
});
