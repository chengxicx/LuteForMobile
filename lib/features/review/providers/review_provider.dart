import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/providers/network_providers.dart';
import '../models/review_models.dart';

/// The review tab, mirroring the web review session (`/review/session`):
/// all cards come from one POST /review/start, each grade is a small
/// POST /review/grade, and undo reverses the latest grading.
enum ReviewPhase {
  /// Landing screen; nothing fetched yet.
  idle,

  /// Session request in flight.
  loading,

  /// Cards on hand; [revealed] / [graded] describe the current card's stage.
  active,

  /// Session over ([nothingDue]) or all cards graded.
  done,

  /// Start/grade failed fatally; [errorMessage] says why.
  error,
}

@immutable
class ReviewState {
  final ReviewPhase phase;

  final List<ReviewCard> cards;
  final int index;

  /// Answer shown, grade buttons visible.
  final bool revealed;

  /// A typed cloze answer was already submitted for the current card
  /// (banner + Next); the grade happened server-side either way.
  final bool graded;
  final bool typedCorrect;
  final String typedAnswer;

  final ReviewUndoInfo? undo;
  final ReviewCounts? counts;

  /// done phase: true when the queue served no cards, false when the
  /// session ran to the end.
  final bool nothingDue;

  final String? errorMessage;

  /// Server reported the fsrs package missing; the UI offers the install.
  final bool needsFsrs;

  /// A grade/undo/install POST is in flight (buttons disabled).
  final bool busy;

  /// One-line status under the progress bar (undo failures, fsrs install).
  final String? notice;

  const ReviewState({
    this.phase = ReviewPhase.idle,
    this.cards = const [],
    this.index = 0,
    this.revealed = false,
    this.graded = false,
    this.typedCorrect = false,
    this.typedAnswer = '',
    this.undo,
    this.counts,
    this.nothingDue = false,
    this.errorMessage,
    this.needsFsrs = false,
    this.busy = false,
    this.notice,
  });

  ReviewCard? get currentCard =>
      index >= 0 && index < cards.length ? cards[index] : null;

  bool get hasUndo => undo != null;

  ReviewState copyWith({
    ReviewPhase? phase,
    List<ReviewCard>? cards,
    int? index,
    bool? revealed,
    bool? graded,
    bool? typedCorrect,
    String? typedAnswer,
    ReviewUndoInfo? undo,
    ReviewCounts? counts,
    bool? nothingDue,
    String? errorMessage,
    bool? needsFsrs,
    bool? busy,
    String? notice,
    bool clearError = false,
    bool clearNotice = false,
    bool clearUndo = false,
  }) {
    return ReviewState(
      phase: phase ?? this.phase,
      cards: cards ?? this.cards,
      index: index ?? this.index,
      revealed: revealed ?? this.revealed,
      graded: graded ?? this.graded,
      typedCorrect: typedCorrect ?? this.typedCorrect,
      typedAnswer: typedAnswer ?? this.typedAnswer,
      undo: clearUndo ? null : (undo ?? this.undo),
      counts: counts ?? this.counts,
      nothingDue: nothingDue ?? this.nothingDue,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      needsFsrs: needsFsrs ?? this.needsFsrs,
      busy: busy ?? this.busy,
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

class ReviewNotifier extends Notifier<ReviewState> {
  @override
  ReviewState build() {
    return const ReviewState();
  }

  /// Start (or restart) a session from POST /review/start.
  Future<void> startSession() async {
    state = ReviewState(phase: ReviewPhase.loading);
    try {
      final payload = await ref.read(apiServiceProvider).startReviewSession();
      final session = ReviewSession.fromMap(_asMap(payload));
      if (session.cards.isEmpty) {
        state = ReviewState(
          phase: ReviewPhase.done,
          nothingDue: true,
          counts: session.counts,
          undo: session.undo,
        );
        return;
      }
      state = ReviewState(
        phase: ReviewPhase.active,
        cards: session.cards,
        index: 0,
        undo: session.undo,
        counts: session.counts,
      );
    } catch (e, stackTrace) {
      ApiLogger.logError('review.startSession', e, stackTrace: stackTrace);
      state = _errorState(e);
    }
  }

  /// Show the answer and the grade buttons.
  void reveal() {
    if (state.phase != ReviewPhase.active || state.graded) return;
    state = state.copyWith(revealed: true);
  }

  /// Typed cloze answer: empty input falls back to a plain reveal; a real
  /// answer is graded server-side (Good when correct, Again when not).
  Future<void> checkTyped(String typed) async {
    if (state.phase != ReviewPhase.active || state.graded || state.busy) return;
    final trimmed = typed.trim();
    if (trimmed.isEmpty) {
      reveal();
      return;
    }
    final card = state.currentCard;
    if (card == null) return;

    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final payload = await ref
          .read(apiServiceProvider)
          .gradeReviewCard(card.id, 3, typed: trimmed);
      final result = ReviewGradeResult.fromMap(_asMap(payload));
      state = state.copyWith(
        busy: false,
        graded: true,
        revealed: false,
        typedCorrect: result.correct,
        typedAnswer: result.answer,
        undo: result.undo,
        clearUndo: result.undo == null,
      );
    } catch (e, stackTrace) {
      ApiLogger.logError('review.checkTyped', e, stackTrace: stackTrace);
      state = _errorState(e);
    }
  }

  /// Grade the current card with [rating] (1 = Again ... 4 = Easy) and
  /// advance.  The intervals preview comes with the card.
  Future<void> grade(int rating) async {
    if (state.phase != ReviewPhase.active || state.graded || state.busy) return;
    final card = state.currentCard;
    if (card == null) return;

    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final payload = await ref
          .read(apiServiceProvider)
          .gradeReviewCard(card.id, rating);
      final result = ReviewGradeResult.fromMap(_asMap(payload));
      _advance(undo: result.undo);
    } catch (e, stackTrace) {
      ApiLogger.logError('review.grade', e, stackTrace: stackTrace);
      state = _errorState(e);
    }
  }

  /// Advance past a typed-checked card (the grade already happened
  /// server-side in [checkTyped]).
  void next() {
    if (state.phase != ReviewPhase.active || !state.graded || state.busy) return;
    _advance(undo: state.undo);
  }

  /// Move past the current card (after a grade or a typed Next).
  void _advance({ReviewUndoInfo? undo}) {
    final next = state.index + 1;
    if (next >= state.cards.length) {
      state = state.copyWith(
        phase: ReviewPhase.done,
        nothingDue: false,
        busy: false,
        undo: undo,
        clearUndo: undo == null,
      );
      return;
    }
    state = state.copyWith(
      index: next,
      revealed: false,
      graded: false,
      typedCorrect: false,
      typedAnswer: '',
      busy: false,
      undo: undo,
      clearUndo: undo == null,
    );
  }

  /// Reverse the latest grading; the undone card comes back on screen.
  Future<void> undo() async {
    if (!state.hasUndo || state.busy) return;
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final payload = await ref.read(apiServiceProvider).undoReviewGrade();
      final map = _asMap(payload);
      final undoneCardId = _readId(map['card_id']);
      final again = map['undo'] == null
          ? null
          : ReviewUndoInfo.fromMap(_asMap(map['undo']));

      final idx = state.cards.indexWhere((c) => c.id == undoneCardId);
      if (idx >= 0) {
        state = state.copyWith(
          index: idx,
          revealed: false,
          graded: false,
          typedCorrect: false,
          typedAnswer: '',
          busy: false,
          undo: again,
          clearUndo: again == null,
        );
      } else {
        // Graded in an earlier session; rebuild one around the undone card.
        await startSession();
      }
    } catch (e, stackTrace) {
      ApiLogger.logError('review.undo', e, stackTrace: stackTrace);
      // Not fatal: the session can continue (web shows a one-line message).
      state = state.copyWith(busy: false, notice: 'Undo failed: ${_message(e)}');
    }
  }

  /// One-click install of the server's fsrs package, then restart the
  /// session the way the web index page reloads after a successful install.
  Future<void> installScheduler() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final payload = await ref.read(apiServiceProvider).installReviewScheduler();
      final result = ReviewSchedulerInstallResult.fromMap(_asMap(payload));
      if (result.ok) {
        await startSession();
      } else {
        state = state.copyWith(busy: false, notice: result.message);
      }
    } catch (e, stackTrace) {
      ApiLogger.logError('review.installScheduler', e, stackTrace: stackTrace);
      state = state.copyWith(busy: false, notice: 'Install failed: ${_message(e)}');
    }
  }

  /// Back to the landing screen (start-over from the error/done states).
  void resetToIdle() {
    state = const ReviewState();
  }

  ReviewState _errorState(Object e) {
    String message = _message(e);
    var needsFsrs = false;
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final map = _asMap(data);
        needsFsrs = map['needs_fsrs'] == true;
        final serverError = map['error'];
        if (serverError != null) message = serverError.toString();
      }
    }
    return ReviewState(
      phase: ReviewPhase.error,
      errorMessage: message,
      needsFsrs: needsFsrs,
      counts: state.counts,
    );
  }

  static String _message(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code != null) return 'Server error $code';
    }
    return e.toString();
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.map((k, v) => MapEntry('$k', v));
    return const {};
  }

  static int _readId(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? -1;
  }
}

final reviewProvider = NotifierProvider<ReviewNotifier, ReviewState>(() {
  return ReviewNotifier();
});
