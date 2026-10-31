import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../settings/providers/settings_provider.dart';
import '../../shadowing/models/shadowing_result.dart';
import '../models/page_data.dart';
import '../models/text_item.dart';
import '../repositories/reader_repository.dart';
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
  /// The furigana script is deliberately not part of it: it is a pure
  /// function of the language id (the server's `_furigana_script`), so one
  /// identity cannot change script, and every page turn re-reads it from
  /// the freshly parsed [PageData] anyway.
  (int, int, int)? _identity;

  /// Readings already fetched this session, keyed by that same identity.
  ///
  /// Flipping back a page (or re-opening a chapter) then paints its ruby at
  /// once instead of going bare for the length of a round trip.  Small and
  /// session-only on purpose: the readings are decoration, and a page that
  /// lost them still reads.
  final Map<String, Map<String, String>> _memo = {};
  static const int _memoMax = 40;

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

    if (!pageNeedsReadings(
      page.paragraphs.expand((p) => p.textItems),
      script: page.furiganaScript,
    )) {
      return;
    }

    unawaited(_load(page, identity));
  }

  Future<void> _load(PageData page, (int, int, int) identity) async {
    final batches = buildFuriganaBatches(
      page.paragraphs.expand((p) => p.textItems),
    );
    if (batches.isEmpty) return;

    final memoKey = '${identity.$1}:${identity.$2}:${identity.$3}';
    final memoed = _memo[memoKey];
    final merged = <String, String>{...?memoed};
    if (merged.isNotEmpty && _identity == identity) {
      // Known page: paint what we have before asking again.
      state = FuriganaState(readings: Map<String, String>.of(merged));
    }

    final repository = ref.read(readerRepositoryProvider);

    // One batch per paragraph, each retried on its own, and every batch
    // published as soon as it lands.
    //
    // The previous shape awaited Future.wait over the whole page and merged
    // once: a single failed request came back as an empty list and was
    // merged as "this paragraph has no readings", so the page ended up
    // half-annotated -- some words with ruby, some without -- and never
    // tried again.  Now a lost batch is retried, and a batch that still
    // fails leaves the others' ruby in place instead of taking the page
    // back to zero.
    await Future.wait(
      batches.map((batch) async {
        final readings = await _fetchBatch(repository, batch, identity.$3);
        if (readings == null) return; // gave up on this paragraph
        if (!ref.mounted || _identity != identity) return;
        mergeBatchReadings(
          merged,
          batch,
          readings.map((token) => token.reading).toList(),
          script: page.furiganaScript,
        );
        state = FuriganaState(readings: Map<String, String>.of(merged));
      }),
    );

    if (!ref.mounted || _identity != identity) return;
    if (merged.isEmpty) return;
    _remember(memoKey, merged);
  }

  /// One paragraph's readings, retried a few times while the link is flaky.
  ///
  /// Returns null when the batch could not be fetched at all -- distinct from
  /// an empty list, which means the text genuinely has nothing to annotate.
  Future<List<ShadowingToken>?> _fetchBatch(
    ReaderRepository repository,
    FuriganaBatch batch,
    int languageId,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final readings = await repository.fetchReadingsOrNull(
        languageId: languageId,
        tokens: batch.tokens,
        fullText: batch.fullText,
      );
      if (readings != null) return readings;
      if (!ref.mounted) return null;
      await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      if (!ref.mounted) return null;
    }
    ApiLogger.logBackground(
      'furigana',
      details: 'batch gave up after 3 attempts (tokens=${batch.tokens.length})',
    );
    return null;
  }

  void _remember(String key, Map<String, String> readings) {
    _memo.remove(key);
    _memo[key] = Map<String, String>.of(readings);
    while (_memo.length > _memoMax) {
      _memo.remove(_memo.keys.first);
    }
  }
}

final furiganaProvider = NotifierProvider<FuriganaNotifier, FuriganaState>(
  FuriganaNotifier.new,
);
