// Models for the server's review queue (lute.review).
//
// The payloads mirror what the web review UI consumes: POST /review/start
// returns `{counts, cards, undo}`, each grade returns the grading result
// plus the next undo info.
import 'package:flutter/foundation.dart';

/// Queue counts as the index page shows them.
@immutable
class ReviewCounts {
  final int due;
  final int newRemaining;
  final int newAllowedToday;
  final int maxNewPerDay;

  const ReviewCounts({
    required this.due,
    required this.newRemaining,
    required this.newAllowedToday,
    required this.maxNewPerDay,
  });

  factory ReviewCounts.fromMap(Map<String, dynamic> map) {
    return ReviewCounts(
      due: _readInt(map['due']),
      newRemaining: _readInt(map['new_remaining']),
      newAllowedToday: _readInt(map['new_allowed_today']),
      maxNewPerDay: _readInt(map['max_new_per_day']),
    );
  }
}

/// Interval previews for the two grade buttons, already formatted by the
/// server (e.g. "3d", "1.2mo"); empty when the scheduler has no answer.
@immutable
class ReviewIntervals {
  final String again;
  final String good;

  const ReviewIntervals({required this.again, required this.good});

  factory ReviewIntervals.fromMap(Map<String, dynamic> map) {
    return ReviewIntervals(
      again: (map['again'] ?? '').toString(),
      good: (map['good'] ?? '').toString(),
    );
  }
}

/// One card of the review session.
///
/// [cardType] is "recognition" (front is the term) or "cloze" (front is the
/// sentence with the term blanked out, in [sentenceBlank]).  [sentence]
/// carries bold markup around the term; [image] is a server-relative
/// /userimages path.
@immutable
class ReviewCard {
  final int id;
  final String cardType;
  final String termText;
  final String translation;
  final String romanization;
  final String sentence;
  final String? image;
  final String langCode;
  final int reps;
  final String? sentenceBlank;
  final ReviewIntervals? intervals;

  const ReviewCard({
    required this.id,
    required this.cardType,
    required this.termText,
    required this.translation,
    required this.romanization,
    required this.sentence,
    required this.image,
    required this.langCode,
    required this.reps,
    required this.sentenceBlank,
    required this.intervals,
  });

  bool get isRecognition => cardType == 'recognition';
  bool get isCloze => cardType == 'cloze';

  factory ReviewCard.fromMap(Map<String, dynamic> map) {
    return ReviewCard(
      id: _readInt(map['id']),
      cardType: (map['card_type'] ?? '').toString(),
      termText: (map['term_text'] ?? '').toString(),
      translation: (map['translation'] ?? '').toString(),
      romanization: (map['romanization'] ?? '').toString(),
      sentence: (map['sentence'] ?? '').toString(),
      image: (map['image'] as String?)?.trim().isEmpty == true
          ? null
          : map['image'] as String?,
      langCode: (map['lang_code'] ?? '').toString(),
      reps: _readInt(map['reps']),
      sentenceBlank: (map['sentence_blank'] as String?),
      intervals: map['intervals'] == null
          ? null
          : ReviewIntervals.fromMap(_asMap(map['intervals'])),
    );
  }
}

/// What an undo would reverse, or null when there is nothing to undo.
@immutable
class ReviewUndoInfo {
  final int cardId;
  final String cardType;
  final String termText;
  final int rating;

  const ReviewUndoInfo({
    required this.cardId,
    required this.cardType,
    required this.termText,
    required this.rating,
  });

  /// "Again" / "Hard" / "Good" / "Easy", matching the server's labels.
  String get ratingLabel => switch (rating) {
    1 => 'Again',
    2 => 'Hard',
    3 => 'Good',
    4 => 'Easy',
    _ => '',
  };

  factory ReviewUndoInfo.fromMap(Map<String, dynamic> map) {
    return ReviewUndoInfo(
      cardId: _readInt(map['card_id']),
      cardType: (map['card_type'] ?? '').toString(),
      termText: (map['term_text'] ?? '').toString(),
      rating: _readInt(map['rating']),
    );
  }
}

/// Result of POST /review/grade.
@immutable
class ReviewGradeResult {
  final bool correct;
  final String answer;
  final ReviewUndoInfo? undo;

  const ReviewGradeResult({
    required this.correct,
    required this.answer,
    required this.undo,
  });

  factory ReviewGradeResult.fromMap(Map<String, dynamic> map) {
    return ReviewGradeResult(
      correct: map['correct'] == true,
      answer: (map['answer'] ?? '').toString(),
      undo: map['undo'] == null
          ? null
          : ReviewUndoInfo.fromMap(_asMap(map['undo'])),
    );
  }
}

/// Result of POST /review/scheduler/install.
@immutable
class ReviewSchedulerInstallResult {
  final bool ok;
  final String message;

  const ReviewSchedulerInstallResult({required this.ok, required this.message});

  factory ReviewSchedulerInstallResult.fromMap(Map<String, dynamic> map) {
    return ReviewSchedulerInstallResult(
      ok: map['ok'] == true,
      message: (map['message'] ?? '').toString(),
    );
  }
}

/// The whole /review/start payload.
@immutable
class ReviewSession {
  final ReviewCounts counts;
  final List<ReviewCard> cards;
  final ReviewUndoInfo? undo;

  const ReviewSession({
    required this.counts,
    required this.cards,
    required this.undo,
  });

  factory ReviewSession.fromMap(Map<String, dynamic> map) {
    final cards = (map['cards'] as List<dynamic>? ?? const [])
        .map((c) => ReviewCard.fromMap(_asMap(c)))
        .toList();
    return ReviewSession(
      counts: ReviewCounts.fromMap(_asMap(map['counts'])),
      cards: cards,
      undo: map['undo'] == null
          ? null
          : ReviewUndoInfo.fromMap(_asMap(map['undo'])),
    );
  }
}

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

/// Tolerantly coerce a nested JSON value to a string-keyed map.  Real dio
/// payloads are already `Map<String, dynamic>`, but test literals and hand
/// built responses can be loose maps; trusting the shape breaks on the
/// first odd caller.
Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return const {};
}
