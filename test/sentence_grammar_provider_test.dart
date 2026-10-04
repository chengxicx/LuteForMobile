import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/grammar/models/grammar_point.dart';
import 'package:song_mobile/features/grammar/providers/grammar_provider.dart';
import 'package:song_mobile/features/grammar/providers/sentence_grammar_provider.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/providers/reader_provider.dart';

/// Pins the sentence grammar feature's logic: which page-analysis points
/// belong to the sentence the reader tapped, what state the word card's
/// Grammar button gets, and when the provider answers from cache instead of
/// hitting the endpoint again.
void main() {
  const sentence = '明日も雨が降っていく。';

  GrammarPoint pointMatching(String example, {String name = '〜ていく'}) =>
      GrammarPoint(
        name: name,
        examples: [GrammarExample(sentence: example, matches: const [])],
      );

  PageData page() => PageData(
    bookId: 7,
    currentPage: 3,
    pageCount: 10,
    paragraphs: [
      Paragraph(
        id: 0,
        textItems: [
          TextItem(
            text: sentence,
            statusClass: '',
            sentenceId: 0,
            paragraphId: 0,
            isStartOfSentence: true,
            order: 0,
          ),
        ],
      ),
    ],
  );

  /// The page pre-analysis a card tap would consult: analysed this page,
  /// finished, no error.
  GrammarState analysedPage({List<GrammarPoint> points = const []}) =>
      GrammarState(analyzedKey: '7/3', points: points);

  /// A container with the reader on [pageData], the Grammar tab holding
  /// [grammarState], and a fake one-sentence endpoint recording its calls.
  ({ProviderContainer container, List<(int, int, String)> calls})
  makeContainer({
    PageData? pageData,
    GrammarState grammarState = const GrammarState(),
    SentenceGrammarFetch? fetch,
  }) {
    final calls = <(int, int, String)>[];
    final container = ProviderContainer(
      overrides: [
        readerProvider.overrideWith(
          () => _FakeReaderNotifier(ReaderState(pageData: pageData ?? page())),
        ),
        grammarProvider.overrideWith(() => _FakeGrammarNotifier(grammarState)),
        sentenceGrammarFetchProvider.overrideWithValue((bookId, pageNum, text) {
          calls.add((bookId, pageNum, text));
          if (fetch == null) {
            throw StateError('unexpected fetch');
          }
          return fetch(bookId, pageNum, text);
        }),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, calls: calls);
  }

  group('SentenceGrammarNotifier.pointsForPage — matching the tapped sentence', () {
    test('an equal example matches', () {
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching(sentence)],
        sentenceText: sentence,
      );
      expect(points, hasLength(1));
      expect(points.single.name, '〜ていく');
    });

    test('whitespace differences do not block the match', () {
      // The reader joins its tokens with spaces, the server's example may not
      // carry the same ones (and vice versa for non-CJK languages).
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching('明日も雨が降って いく。')],
        sentenceText: sentence,
      );
      expect(points, hasLength(1));
    });

    test('zero-width characters inside the server example do not block it', () {
      // Lute's page text carries U+200B at furigana boundaries (来\u200bて),
      // and those flow into the server's example sentences -- the reader's
      // token-joined sentence has none.  Seen live on book 277: every button
      // greyed out until the normaliser learned to strip them.
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching('「もう来\u200bてください」')],
        sentenceText: '「もう来てください」',
      );
      expect(points, hasLength(1));
    });

    test('a server-merged example (subtitle lines) still matches', () {
      // Two reader sentences, no ending punctuation on the first, merged by
      // the server into one sentence: the tapped line is a substring.
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching('明日も雨が降っていく。傘を持って行こう。')],
        sentenceText: sentence,
      );
      expect(points, hasLength(1));
    });

    test('a server-split example still matches', () {
      // The reader saw one sentence, the server split it in two.
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching('明日も雨が降っていく。')],
        sentenceText: '明日も雨が降っていく。傘を持って行こう。',
      );
      expect(points, hasLength(1));
    });

    test('unrelated examples match nothing', () {
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching('昨日は晴れだった。', name: '〜た')],
        sentenceText: sentence,
      );
      expect(points, isEmpty);
    });

    test('an empty sentence matches nothing', () {
      final points = SentenceGrammarNotifier.pointsForPage(
        pagePoints: [pointMatching(sentence)],
        sentenceText: '   ',
      );
      expect(points, isEmpty);
    });
  });

  group('presenceFor — the word card Grammar button state', () {
    test('valid page analysis + sentence matched -> yes', () {
      final c = makeContainer(
        grammarState: analysedPage(points: [pointMatching(sentence)]),
      );
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.yes,
      );
    });

    test('valid page analysis + nothing matched -> no', () {
      final c = makeContainer(
        grammarState: analysedPage(points: [pointMatching('昨日は晴れだった。')]),
      );
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.no,
      );
    });

    test('analysis still running -> unknown, never grey', () {
      final c = makeContainer(
        grammarState: const GrammarState(isLoading: true, analyzedKey: '7/3'),
      );
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.unknown,
      );
    });

    test('analysis failed -> unknown (an error proves nothing)', () {
      final c = makeContainer(
        grammarState: const GrammarState(
          analyzedKey: '7/3',
          errorMessage: 'boom',
        ),
      );
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.unknown,
      );
    });

    test('analysis is for another page -> unknown', () {
      final p = page();
      final c = makeContainer(
        pageData: PageData(
          bookId: p.bookId,
          currentPage: p.currentPage + 1,
          pageCount: p.pageCount,
          paragraphs: p.paragraphs,
        ),
        grammarState: analysedPage(points: [pointMatching(sentence)]),
      );
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.unknown,
      );
    });

    test('no page loaded -> unknown', () {
      final c = makeContainer(pageData: null);
      expect(
        c.container.read(sentenceGrammarProvider.notifier).presenceFor(sentence),
        GrammarPresence.unknown,
      );
    });
  });

  group('getSentenceGrammar', () {
    test('answers from the page cache without a request', () async {
      final c = makeContainer(
        grammarState: analysedPage(points: [pointMatching(sentence)]),
      );
      final points = await c.container
          .read(sentenceGrammarProvider.notifier)
          .getSentenceGrammar(sentence);
      expect(points, hasLength(1));
      expect(c.calls, isEmpty);
    });

    test('falls back to a one-sentence request and caches the answer', () async {
      final fallback = [pointMatching(sentence, name: '〜ていく (fallback)')];
      final c = makeContainer(
        fetch: (bookId, pageNum, text) async {
          expect(bookId, 7);
          expect(pageNum, 3);
          expect(text, sentence);
          return fallback;
        },
      );
      final notifier = c.container.read(sentenceGrammarProvider.notifier);

      expect(await notifier.getSentenceGrammar(sentence), fallback);
      expect(c.calls, hasLength(1));

      // Second open of the same sentence: served from the per-sentence cache.
      expect(await notifier.getSentenceGrammar(sentence), fallback);
      expect(c.calls, hasLength(1));
    });

    test('concurrent callers share one in-flight request', () async {
      final gate = Completer<List<GrammarPoint>>();
      final c = makeContainer(fetch: (_, _, _) => gate.future);
      final notifier = c.container.read(sentenceGrammarProvider.notifier);

      final first = notifier.getSentenceGrammar(sentence);
      final second = notifier.getSentenceGrammar(sentence);
      gate.complete([pointMatching(sentence)]);

      expect(await first, hasLength(1));
      expect(await second, hasLength(1));
      expect(c.calls, hasLength(1));
    });

    test('a failed request cools down; force retries', () async {
      var attempts = 0;
      final c = makeContainer(fetch: (_, _, _) async {
        attempts++;
        throw Exception('server down');
      });
      final notifier = c.container.read(sentenceGrammarProvider.notifier);

      await expectLater(
        notifier.getSentenceGrammar(sentence),
        throwsA(anything),
      );
      expect(attempts, 1);

      // Within the cooldown the stored error is rethrown without a request.
      await expectLater(
        notifier.getSentenceGrammar(sentence),
        throwsA(anything),
      );
      expect(attempts, 1);

      // Retry on the error screen forces a real request.
      await expectLater(
        notifier.getSentenceGrammar(sentence, force: true),
        throwsA(anything),
      );
      expect(attempts, 2);
    });
  });
}

class _FakeReaderNotifier extends ReaderNotifier {
  _FakeReaderNotifier(this._state);

  final ReaderState _state;

  @override
  ReaderState build() => _state;
}

class _FakeGrammarNotifier extends GrammarNotifier {
  _FakeGrammarNotifier(this._state);

  final GrammarState _state;

  @override
  GrammarState build() => _state;
}
