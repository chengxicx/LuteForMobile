import 'dart:convert';

/// One user action that has not reached the server yet.
///
/// The outbox stores **intents**, not HTTP requests.  That is forced by the
/// write endpoints: `POST /read/edit_term/<id>` submits a whole term, so a
/// request built offline cannot be replayed later without first fetching the
/// current form — and a request captured at tap time would carry a stale
/// snapshot.  Storing the *goal* ("this term should be status 3") lets the
/// flush build a correct request at the moment it can actually talk to the
/// server.
///
/// Deliberately a plain Dart sealed class with hand-written JSON: no
/// `@HiveType`, no codegen, no `hive_registrar.g.dart` churn.  The box holds
/// `String`s and this class owns the encoding.
sealed class PendingIntent {
  const PendingIntent({
    required this.seq,
    this.attempts = 0,
    this.nextAttemptAtMs = 0,
    this.failed = false,
  });

  /// Monotonic, assigned at enqueue time.  Flushing in `seq` order preserves
  /// the causal order of the user's actions.
  final int seq;

  /// How many times a flush has tried and failed (transient failures only).
  final int attempts;

  /// Wall-clock ms before which this intent must not be retried.
  final int nextAttemptAtMs;

  /// Set when the failure was permanent (4xx, deleted term, retry budget
  /// exhausted).  Failed intents stay visible in the UI so the user can
  /// retry or discard them, but they are skipped by the flush.
  final bool failed;

  /// Identity used for coalescing: two intents sharing a key are the same
  /// intent and merge into one.  Type-prefixed so keys never collide across
  /// kinds.
  String get coalesceKey;

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  /// Back off after a transient failure.  A fresh user action does **not**
  /// go through here — it creates a new intent, which resets the budget.
  PendingIntent withRetry({required int attempts, required int nextAttemptAtMs});

  /// Give up on this intent but keep it around for the user to see.
  PendingIntent asFailed();

  /// Re-arm a failed intent after the user taps Retry: clear the failure flag
  /// and the retry budget so the next flush picks it up immediately.
  ///
  /// Kept concrete in the base so the three subclasses do not each need a
  /// near-identical `revive`; the switch is exhaustive because the class is
  /// sealed.
  PendingIntent revived() => switch (this) {
    TermEditIntent i => i.copyWith(
      attempts: 0,
      nextAttemptAtMs: 0,
      failed: false,
    ),
    TermCreateIntent i => i.copyWith(
      attempts: 0,
      nextAttemptAtMs: 0,
      failed: false,
    ),
    PageDoneIntent i => i.copyWith(
      attempts: 0,
      nextAttemptAtMs: 0,
      failed: false,
    ),
  };

  static PendingIntent decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final kind = json['kind'] as String?;
    switch (kind) {
      case TermEditIntent.kind:
        return TermEditIntent.fromJson(json);
      case TermCreateIntent.kind:
        return TermCreateIntent.fromJson(json);
      case PageDoneIntent.kind:
        return PageDoneIntent.fromJson(json);
      default:
        throw FormatException('Unknown pending intent kind: $kind');
    }
  }
}

/// "This term's status (and possibly its whole form) should be this."
///
/// Covers both the double-tap status cycle and a full save from the term
/// editor — they hit the same endpoint, so they coalesce onto the same key.
class TermEditIntent extends PendingIntent {
  const TermEditIntent({
    required this.termId,
    required this.status,
    this.formData,
    this.langId,
    required super.seq,
    super.attempts,
    super.nextAttemptAtMs,
    super.failed,
  });

  static const String kind = 'term_edit';

  final int termId;
  final String status;

  /// The full form snapshot, when the user actually opened and saved the
  /// editor.  Null for a bare status cycle, in which case the flush fetches
  /// the form first so the other fields are not blanked.
  final Map<String, dynamic>? formData;

  final int? langId;

  @override
  String get coalesceKey => 'term:$termId';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'seq': seq,
    'attempts': attempts,
    'nextAttemptAtMs': nextAttemptAtMs,
    'failed': failed,
    'termId': termId,
    'status': status,
    if (formData != null) 'formData': formData,
    if (langId != null) 'langId': langId,
  };

  TermEditIntent copyWith({
    String? status,
    Map<String, dynamic>? formData,
    int? langId,
    int? seq,
    int? attempts,
    int? nextAttemptAtMs,
    bool? failed,
  }) {
    return TermEditIntent(
      termId: termId,
      status: status ?? this.status,
      formData: formData ?? this.formData,
      langId: langId ?? this.langId,
      seq: seq ?? this.seq,
      attempts: attempts ?? this.attempts,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
      failed: failed ?? this.failed,
    );
  }

  @override
  TermEditIntent withRetry({
    required int attempts,
    required int nextAttemptAtMs,
  }) => copyWith(attempts: attempts, nextAttemptAtMs: nextAttemptAtMs);

  @override
  TermEditIntent asFailed() => copyWith(failed: true);

  static TermEditIntent fromJson(Map<String, dynamic> json) {
    final rawForm = json['formData'];
    return TermEditIntent(
      termId: json['termId'] as int,
      status: json['status'] as String,
      formData: rawForm is Map ? rawForm.cast<String, dynamic>() : null,
      langId: json['langId'] as int?,
      seq: json['seq'] as int,
      attempts: json['attempts'] as int? ?? 0,
      nextAttemptAtMs: json['nextAttemptAtMs'] as int? ?? 0,
      failed: json['failed'] as bool? ?? false,
    );
  }
}

/// "Create this term in this language."  The offline path for a word that has
/// no server id yet, so there is nothing to edit.
class TermCreateIntent extends PendingIntent {
  const TermCreateIntent({
    required this.langId,
    required this.text,
    required this.formData,
    required super.seq,
    super.attempts,
    super.nextAttemptAtMs,
    super.failed,
  });

  static const String kind = 'term_create';

  final int langId;
  final String text;
  final Map<String, dynamic> formData;

  @override
  String get coalesceKey => 'new:$langId:$text';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'seq': seq,
    'attempts': attempts,
    'nextAttemptAtMs': nextAttemptAtMs,
    'failed': failed,
    'langId': langId,
    'text': text,
    'formData': formData,
  };

  TermCreateIntent copyWith({
    Map<String, dynamic>? formData,
    int? seq,
    int? attempts,
    int? nextAttemptAtMs,
    bool? failed,
  }) {
    return TermCreateIntent(
      langId: langId,
      text: text,
      formData: formData ?? this.formData,
      seq: seq ?? this.seq,
      attempts: attempts ?? this.attempts,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
      failed: failed ?? this.failed,
    );
  }

  @override
  TermCreateIntent withRetry({
    required int attempts,
    required int nextAttemptAtMs,
  }) => copyWith(attempts: attempts, nextAttemptAtMs: nextAttemptAtMs);

  @override
  TermCreateIntent asFailed() => copyWith(failed: true);

  static TermCreateIntent fromJson(Map<String, dynamic> json) {
    return TermCreateIntent(
      langId: json['langId'] as int,
      text: json['text'] as String,
      formData: (json['formData'] as Map).cast<String, dynamic>(),
      seq: json['seq'] as int,
      attempts: json['attempts'] as int? ?? 0,
      nextAttemptAtMs: json['nextAttemptAtMs'] as int? ?? 0,
      failed: json['failed'] as bool? ?? false,
    );
  }
}

/// "This page is read" and/or "this page's remaining unknown words are known".
///
/// Two independent booleans rather than one enum, because the two server
/// effects are not mutually exclusive — see [coalesce].
class PageDoneIntent extends PendingIntent {
  const PageDoneIntent({
    required this.bookId,
    required this.pageNum,
    required this.markRead,
    required this.markKnown,
    required super.seq,
    super.attempts,
    super.nextAttemptAtMs,
    super.failed,
  });

  static const String kind = 'page_done';

  final int bookId;
  final int pageNum;

  /// `POST /read/page_done` with `restknown=0`.  Always sent when set: it is
  /// what records the read date and the words-read statistics.
  final bool markRead;

  /// `restknown=1` — mark the page's remaining *unknown* words as well known.
  /// A strict superset of [markRead] on the server (`mark_page_read` records
  /// the stats either way and only the unknowns-to-known step is conditional).
  final bool markKnown;

  @override
  String get coalesceKey => 'page:$bookId:$pageNum';

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'seq': seq,
    'attempts': attempts,
    'nextAttemptAtMs': nextAttemptAtMs,
    'failed': failed,
    'bookId': bookId,
    'pageNum': pageNum,
    'markRead': markRead,
    'markKnown': markKnown,
  };

  PageDoneIntent copyWith({
    bool? markRead,
    bool? markKnown,
    int? seq,
    int? attempts,
    int? nextAttemptAtMs,
    bool? failed,
  }) {
    return PageDoneIntent(
      bookId: bookId,
      pageNum: pageNum,
      markRead: markRead ?? this.markRead,
      markKnown: markKnown ?? this.markKnown,
      seq: seq ?? this.seq,
      attempts: attempts ?? this.attempts,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
      failed: failed ?? this.failed,
    );
  }

  @override
  PageDoneIntent withRetry({
    required int attempts,
    required int nextAttemptAtMs,
  }) => copyWith(attempts: attempts, nextAttemptAtMs: nextAttemptAtMs);

  @override
  PageDoneIntent asFailed() => copyWith(failed: true);

  static PageDoneIntent fromJson(Map<String, dynamic> json) {
    return PageDoneIntent(
      bookId: json['bookId'] as int,
      pageNum: json['pageNum'] as int,
      markRead: json['markRead'] as bool? ?? false,
      markKnown: json['markKnown'] as bool? ?? false,
      seq: json['seq'] as int,
      attempts: json['attempts'] as int? ?? 0,
      nextAttemptAtMs: json['nextAttemptAtMs'] as int? ?? 0,
      failed: json['failed'] as bool? ?? false,
    );
  }
}

/// Fold [newer] into [older], where both share a [PendingIntent.coalesceKey].
///
/// Pure, and the only place coalescing rules live — the flush never has to
/// reason about ordering because merging already made the order irrelevant.
PendingIntent coalesce(PendingIntent older, PendingIntent newer) {
  // [newer] is always a freshly built intent, so it carries seq = the new
  // value, attempts = 0, failed = false.  A new user action therefore also
  // resets the retry budget, which is what you want: it is a fresh attempt
  // at a goal the user just expressed again.
  if (older is TermEditIntent && newer is TermEditIntent) {
    return newer.copyWith(
      // Keep the older full-form snapshot when the newer intent is a bare
      // status cycle.  Otherwise "edit the form, then double-tap the word"
      // would throw away the form fields the user typed.
      formData: newer.formData ?? older.formData,
      langId: newer.langId ?? older.langId,
    );
  }

  if (older is PageDoneIntent && newer is PageDoneIntent) {
    return newer.copyWith(
      // OR, not last-write-wins.  `markKnown` is a monotonic "mark the rest
      // of this page known" action, and `_markPageKnown` immediately
      // navigates, which fires a plain `markRead` for the same page.  Under
      // LWW that navigation would erase the All Known the user just asked
      // for.
      markRead: older.markRead || newer.markRead,
      markKnown: older.markKnown || newer.markKnown,
    );
  }

  if (older is TermCreateIntent && newer is TermCreateIntent) {
    // The whole form is the payload and the newest one is the most complete
    // thing the user typed, so last-write-wins is correct here.
    return newer;
  }

  // Same key but different kinds: impossible while keys stay type-prefixed.
  // Prefer the newer intent rather than dropping the user's latest action.
  return newer;
}
