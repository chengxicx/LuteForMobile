import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/features/review/providers/review_provider.dart';
import 'package:song_mobile/shared/providers/network_providers.dart';
import 'package:mocktail/mocktail.dart';

class MockApiService extends Mock implements ApiService {}

/// Per-test harness: mocks the API layer and exposes the provider state
/// (getters are illegal inside main(), hence the tiny class).
class Harness {
  final MockApiService api = MockApiService();
  late final ProviderContainer container = ProviderContainer(
    overrides: [apiServiceProvider.overrideWithValue(api)],
  );

  ReviewState get state => container.read(reviewProvider);
  ReviewNotifier get notifier => container.read(reviewProvider.notifier);

  void dispose() => container.dispose();
}

/// Card payload in the shape POST /review/start actually serves.
Map<String, dynamic> _card(int id, {String type = 'recognition'}) {
  return {
    'id': id,
    'card_type': type,
    'term_text': '言葉',
    'translation': 'word',
    'romanization': 'kotoba',
    'sentence': 'この<b>言葉</b>は難しい。',
    'image': null,
    'lang_code': 'ja',
    'reps': id,
    if (type == 'cloze')
      'sentence_blank': 'この<span class="cloze-blank">[...]</span>は難しい。',
    'intervals': {'again': '1m', 'good': '3d'},
  };
}

Map<String, dynamic> _gradePayload({required int undoneCardId}) {
  return {
    'correct': true,
    'answer': '言葉',
    'state': 2,
    'due': '2026-09-26T00:00:00',
    'undo': {
      'card_id': undoneCardId,
      'card_type': 'recognition',
      'term_text': '言葉',
      'rating': 3,
    },
  };
}

void main() {
  test('startSession with cards lands on the first active card', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {
        'counts': {
          'due': 2,
          'new_remaining': 0,
          'new_allowed_today': 5,
          'max_new_per_day': 20,
        },
        'cards': [_card(1), _card(2)],
        'undo': null,
      },
    );

    await h.notifier.startSession();

    expect(h.state.phase, ReviewPhase.active);
    expect(h.state.index, 0);
    expect(h.state.cards.length, 2);
    expect(h.state.counts!.due, 2);
  });

  test('empty queue ends the session as nothing-due with counts', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {
        'counts': {
          'due': 0,
          'new_remaining': 7,
          'new_allowed_today': 0,
          'max_new_per_day': 20,
        },
        'cards': <Map<String, dynamic>>[],
        'undo': null,
      },
    );

    await h.notifier.startSession();

    expect(h.state.phase, ReviewPhase.done);
    expect(h.state.nothingDue, isTrue);
    expect(h.state.counts!.newRemaining, 7);
  });

  test('grade posts to the server and advances to the next card', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {'counts': const {}, 'cards': [_card(1), _card(2)], 'undo': null},
    );
    await h.notifier.startSession();

    when(
      () => h.api.gradeReviewCard(1, 3),
    ).thenAnswer((_) async => _gradePayload(undoneCardId: 1));

    await h.notifier.grade(3);

    verify(() => h.api.gradeReviewCard(1, 3)).called(1);
    expect(h.state.index, 1);
    expect(h.state.revealed, isFalse);
    expect(h.state.undo!.cardId, 1);
  });

  test('last grade ends the session', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {'counts': const {}, 'cards': [_card(1)], 'undo': null},
    );
    await h.notifier.startSession();

    when(
      () => h.api.gradeReviewCard(1, 1),
    ).thenAnswer((_) async => _gradePayload(undoneCardId: 1));

    await h.notifier.grade(1);

    expect(h.state.phase, ReviewPhase.done);
    expect(h.state.nothingDue, isFalse);
  });

  test('typed cloze answer surfaces the server verdict and Next advances',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {
        'counts': const {},
        'cards': [_card(1, type: 'cloze'), _card(2)],
        'undo': null,
      },
    );
    await h.notifier.startSession();

    when(() => h.api.gradeReviewCard(1, 3, typed: 'wrong words')).thenAnswer(
      (_) async => {
        'correct': false,
        'answer': '言葉',
        'undo': {
          'card_id': 1,
          'card_type': 'cloze',
          'term_text': '言葉',
          'rating': 1,
        },
      },
    );

    await h.notifier.checkTyped('wrong words');

    expect(h.state.graded, isTrue);
    expect(h.state.typedCorrect, isFalse);
    expect(h.state.typedAnswer, '言葉');

    h.notifier.next();
    expect(h.state.index, 1);
    expect(h.state.graded, isFalse);
  });

  test('empty typed input falls back to a plain reveal', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {
        'counts': const {},
        'cards': [_card(1, type: 'cloze')],
        'undo': null,
      },
    );
    await h.notifier.startSession();

    await h.notifier.checkTyped('   ');

    verifyNever(
      () => h.api.gradeReviewCard(any(), any(), typed: any(named: 'typed')),
    );
    expect(h.state.revealed, isTrue);
    expect(h.state.graded, isFalse);
  });

  test('undo brings the undone card back on screen', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {'counts': const {}, 'cards': [_card(1), _card(2)], 'undo': null},
    );
    await h.notifier.startSession();
    when(
      () => h.api.gradeReviewCard(1, 3),
    ).thenAnswer((_) async => _gradePayload(undoneCardId: 1));
    await h.notifier.grade(3);
    expect(h.state.index, 1);

    when(() => h.api.undoReviewGrade()).thenAnswer(
      (_) async => {
        'card_id': 1,
        'card_type': 'recognition',
        'term_text': '言葉',
        'rating': 3,
        'undo': null,
      },
    );

    await h.notifier.undo();

    expect(h.state.index, 0);
    expect(h.state.currentCard!.id, 1);
    expect(h.state.revealed, isFalse);
    expect(h.state.hasUndo, isFalse);
  });

  test('missing fsrs package maps to the error phase with needsFsrs',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/review/start'),
        response: Response(
          requestOptions: RequestOptions(path: '/review/start'),
          statusCode: 400,
          data: {'error': 'fsrs is not installed', 'needs_fsrs': true},
        ),
      ),
    );

    await h.notifier.startSession();

    expect(h.state.phase, ReviewPhase.error);
    expect(h.state.needsFsrs, isTrue);
    expect(h.state.errorMessage, 'fsrs is not installed');
  });

  test('reveal is blocked once the card was typed-graded', () async {
    final h = Harness();
    addTearDown(h.dispose);
    when(() => h.api.startReviewSession()).thenAnswer(
      (_) async => {
        'counts': const {},
        'cards': [_card(1, type: 'cloze')],
        'undo': null,
      },
    );
    await h.notifier.startSession();
    when(
      () => h.api.gradeReviewCard(1, 3, typed: '言葉'),
    ).thenAnswer((_) async => _gradePayload(undoneCardId: 1));

    await h.notifier.checkTyped('言葉');
    h.notifier.reveal();

    expect(h.state.graded, isTrue);
    expect(h.state.revealed, isFalse);
  });
}
