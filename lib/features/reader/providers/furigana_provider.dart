import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/providers/settings_provider.dart';
import '../models/page_data.dart';
import '../models/text_item.dart';
import '../utils/furigana_annotator.dart';
import 'reader_provider.dart';

/// Whether the reader should annotate [page] with readings.
///
/// One definition on purpose: the notifier uses it to decide what to fetch,
/// and the widget that hands the flag down to `TextDisplay` uses it to decide
/// whether to reserve the reading slots.  If the two disagreed, the layout
/// and the readings would disagree about whether the page is annotated.
///
/// Manga and PDF pages are excluded: their words are positioned boxes
/// overlaid on a page image (manga's columns are one cell per character), so
/// a reading above each cell would break the layout and add nothing legible.
/// The web reader skips the same two page types.
bool furiganaActive(PageData? page, {required bool enabled}) {
  if (page == null || !enabled) return false;
  if (page.furiganaLangId == null) return false;
  if (page.isManga || page.isPdf) return false;
  return true;
}

/// Furigana readings for the page on screen, keyed by [TextItem.renderKey].
///
/// The reader paints a reading above every word cell whose key is present
/// here.  Cells without one keep an empty -- but equally tall -- slot, so the
/// page does not reflow when the readings land.
@immutable
class FuriganaState {
  final Map<String, String> readings;

  const FuriganaState({this.readings = const {}});

  /// The reading to show above [item], or null when it has none.
  String? readingFor(TextItem item) => readings[item.renderKey];

  bool get hasReadings => readings.isNotEmpty;
}

/// Fetches the page's readings and keeps them in step with the page on
/// screen.
///
/// Readings come from the same endpoint the shadowing panel uses
/// (`POST /read/shadowing/readings`), one request per paragraph -- the web
/// reader's batching, so each request carries a paragraph's worth of sentence
/// context and the server can read each morpheme in it (一つ -> ひとつ).
class FuriganaNotifier extends Notifier<FuriganaState> {
  /// Identity of the page the current readings belong to (or are being
  /// fetched for): book, page and language.  An answer that arrives after
  /// the reader moved on is dropped rather than painted over the new page.
  (int, int, int)? _identity;

  @override
  FuriganaState build() {
    ref.listen(readerProvider, (previous, next) {
      _onPageChanged(next.pageData);
    });
    ref.listen(settingsProvider, (previous, next) {
      if (previous?.furiganaEnabled != next.furiganaEnabled) {
        _onPageChanged(ref.read(readerProvider).pageData);
      }
    });
    // The listeners only fire on *change*, so a reader that is already
    // showing a page when this provider is first watched would never be
    // annotated.  Deferred a microtask so state is not written while build()
    // is still running.
    Future.microtask(() {
      if (!ref.mounted) return;
      _onPageChanged(ref.read(readerProvider).pageData);
    });
    return const FuriganaState();
  }

  void _onPageChanged(PageData? page) {
    final enabled = ref.read(settingsProvider).furiganaEnabled;

    if (!furiganaActive(page, enabled: enabled)) {
      _identity = null;
      if (state.hasReadings) state = const FuriganaState();
      return;
    }

    final identity = (page!.bookId, page.currentPage, page.furiganaLangId!);
    if (_identity == identity) return;
    _identity = identity;

    // Drop the outgoing page's readings at once: the keys are page-local
    // (paragraph / order / word id), so keeping them would paint the previous
    // page's ruby over this page's words wherever the numbers line up.
    if (state.hasReadings) state = const FuriganaState();

    if (!pageNeedsReadings(page.paragraphs.expand((p) => p.textItems))) return;

    unawaited(_load(page, identity));
  }

  Future<void> _load(PageData page, (int, int, int) identity) async {
    final batches = buildFuriganaBatches(
      page.paragraphs.expand((p) => p.textItems),
    );
    if (batches.isEmpty) return;

    final repository = ref.read(readerRepositoryProvider);
    final responses = await Future.wait(
      batches.map(
        (batch) => repository.fetchReadings(
          languageId: identity.$3,
          tokens: batch.tokens,
          fullText: batch.fullText,
        ),
      ),
    );

    // The reader moved on (page turn, book change, or the setting flipped)
    // while we were asking: the answer belongs to a page no longer shown.
    if (!ref.mounted || _identity != identity) return;

    final merged = <String, String>{};
    for (var i = 0; i < batches.length; i++) {
      mergeBatchReadings(
        merged,
        batches[i],
        responses[i].map((token) => token.reading).toList(),
      );
    }
    if (merged.isEmpty) return;
    state = FuriganaState(readings: merged);
  }
}

final furiganaProvider = NotifierProvider<FuriganaNotifier, FuriganaState>(
  FuriganaNotifier.new,
);
