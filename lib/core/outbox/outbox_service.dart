import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';

import '../cache/cache_logger.dart';
import '../network/content_service.dart';
import '../network/session_manager.dart';
import 'models/pending_intent.dart';
import 'outbox_flush_policy.dart';
import 'outbox_store.dart';

/// What the UI needs to know about the outbox.
@immutable
class OutboxState {
  const OutboxState({
    this.intents = const [],
    this.isSyncing = false,
    this.lastError,
  });

  /// Every intent still owed to the server, including failed ones (they stay
  /// visible so the user can retry or discard them).
  final List<PendingIntent> intents;

  final bool isSyncing;
  final String? lastError;

  int get pendingCount => intents.where((i) => !i.failed).length;
  int get failedCount => intents.where((i) => i.failed).length;
  bool get isEmpty => intents.isEmpty;

  OutboxState copyWith({
    List<PendingIntent>? intents,
    bool? isSyncing,
    String? lastError,
  }) {
    return OutboxState(
      intents: intents ?? this.intents,
      isSyncing: isSyncing ?? this.isSyncing,
      lastError: lastError,
    );
  }
}

enum _Outcome { sent, transient, permanent, needsLogin }

/// Owns the pending intents: coalescing, persistence, and replay.
///
/// Deliberately **not** built on `ApiRequestQueue`, and every replay is sent
/// with `bypassQueue: true` so it cannot be absorbed by it.  That queue
/// drops an intent after a single failed replay, refuses the second
/// `GET /read/edit_term/...` (killing the GET-then-POST this needs), and
/// lives only in memory.  The outbox needs the opposite of all three.
///
/// (It used to be four: the queue also replayed with a bare `Dio()` that
/// carried no session interceptor, so a replay went out unauthenticated and
/// the server answered 302.  That is fixed -- the queue now replays through
/// the app's own Dio, see [QueuedDioInterceptor._dio] -- but the other three
/// still hold, so the outbox keeps its own replay path.)
///
/// Bypassing it also keeps the outbox honest about failure.  Absorbed into
/// the queue, a request on a dead link would neither fail nor succeed -- the
/// edit would sit in limbo, reported as pending forever, and the retry budget
/// that is supposed to eventually give up would never advance.
class OutboxService {
  OutboxService({required OutboxStore store, required ContentService content})
    : _store = store,
      _content = content;

  final OutboxStore _store;
  final ContentService _content;

  /// Keyed by [PendingIntent.coalesceKey], so the map *is* the coalescing:
  /// there is at most one intent per identity.
  final Map<String, PendingIntent> _intents = {};

  int _nextSeq = 0;
  bool _isFlushing = false;

  /// Fired whenever the intent set changes, so the notifier can republish.
  VoidCallback? onChanged;

  /// Fired with the intents that just reached the server, so caches holding
  /// the pre-sync view can be dropped and authority handed back to the server.
  void Function(List<PendingIntent> sent)? onSent;

  bool get isFlushing => _isFlushing;

  /// Oldest first — the order the flush will use.
  List<PendingIntent> get intents {
    final list = _intents.values.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return list;
  }

  /// Load persisted intents by reading the store.
  Future<void> hydrate() async => seed(await _store.readAll());

  /// Seed from entries that were already read.
  ///
  /// Synchronous on purpose: `main` reads the box before `runApp` and injects
  /// the result, so the very first frame already knows about pending edits.
  /// Loading them asynchronously *after* the first frame would let an offline
  /// edit render in its stale server colour for a frame and then flip.
  void seed(Map<String, String> raw) {
    var maxSeq = -1;

    for (final entry in raw.entries) {
      try {
        final intent = PendingIntent.decode(entry.value);
        _intents[entry.key] = intent;
        if (intent.seq > maxSeq) maxSeq = intent.seq;
      } catch (e) {
        // A single corrupt record must not cost the user every other edit.
        CacheLogger.logError('outbox seed', e);
      }
    }

    if (maxSeq + 1 > _nextSeq) _nextSeq = maxSeq + 1;
    onChanged?.call();
  }

  Future<void> enqueueTermStatus(
    int termId,
    String status, {
    int? langId,
    Map<String, dynamic>? formData,
  }) {
    return _enqueue(
      TermEditIntent(
        termId: termId,
        status: status,
        langId: langId,
        formData: formData,
        seq: _nextSeq,
      ),
    );
  }

  Future<void> enqueueTermCreate(
    int langId,
    String text,
    Map<String, dynamic> formData,
  ) {
    return _enqueue(
      TermCreateIntent(
        langId: langId,
        text: text,
        formData: formData,
        seq: _nextSeq,
      ),
    );
  }

  Future<void> enqueuePageDone({
    required int bookId,
    required int pageNum,
    bool markRead = false,
    bool markKnown = false,
  }) {
    if (!markRead && !markKnown) return Future<void>.value();
    return _enqueue(
      PageDoneIntent(
        bookId: bookId,
        pageNum: pageNum,
        markRead: markRead,
        markKnown: markKnown,
        seq: _nextSeq,
      ),
    );
  }

  Future<void> _enqueue(PendingIntent intent) async {
    // The new intent always takes the newest seq, even when it merges into an
    // existing one: it is the most recent expression of the user's wish, so it
    // should be replayed last.
    _nextSeq = intent.seq + 1;

    final existing = _intents[intent.coalesceKey];
    final merged = existing == null ? intent : coalesce(existing, intent);

    _intents[merged.coalesceKey] = merged;
    await _write(merged);
    onChanged?.call();
  }

  Future<void> discard(String coalesceKey) async {
    if (_intents.remove(coalesceKey) == null) return;
    await _store.delete(coalesceKey);
    onChanged?.call();
  }

  /// Drop a failed intent and re-arm it for another attempt.
  Future<void> retry(String coalesceKey) async {
    final intent = _intents[coalesceKey];
    if (intent == null) return;

    final rearmed = intent.revived();
    _intents[coalesceKey] = rearmed;
    await _write(rearmed);
    onChanged?.call();
  }

  Future<void> clearAll() async {
    _intents.clear();
    await _store.clear();
    onChanged?.call();
  }

  /// Send everything that is due.  Single-flight: a second call while a flush
  /// is running is a no-op, so a reachability flip plus the periodic timer
  /// cannot produce overlapping replays of the same intent.
  Future<void> flush() async {
    if (_isFlushing) return;
    _isFlushing = true;
    onChanged?.call();

    final sent = <PendingIntent>[];
    try {
      final due = planFlush(
        _intents.values,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      for (final intent in due) {
        final outcome = await _replay(intent);
        switch (outcome) {
          case _Outcome.sent:
            _intents.remove(intent.coalesceKey);
            await _store.delete(intent.coalesceKey);
            sent.add(intent);
          case _Outcome.permanent:
            await _markFailed(intent);
          case _Outcome.needsLogin:
            // Pause the whole round: every further intent would fail the same
            // way, and discarding them would lose the user's edits.
            CacheLogger.log('outbox paused: login required');
            return;
          case _Outcome.transient:
            // The link is down.  Back this one off and stop: the rest of the
            // queue would fail identically.
            await _backOff(intent);
            return;
        }
      }
    } finally {
      // Intents that *did* land must be reported even when a later one
      // aborted the round.  Their caches still hold the pre-sync view, and
      // the next flush may be minutes away -- until then a re-read of that
      // page would show the status the sync just replaced.
      if (sent.isNotEmpty) onSent?.call(sent);
      _isFlushing = false;
      onChanged?.call();
    }
  }

  Future<_Outcome> _replay(PendingIntent intent) async {
    try {
      switch (intent) {
        case TermEditIntent():
          await _replayTermEdit(intent);
        case TermCreateIntent():
          await _content.saveTermForm(
            intent.langId,
            intent.text,
            intent.formData,
            bypassQueue: true,
          );
        case PageDoneIntent():
          await _replayPageDone(intent);
      }
      return _Outcome.sent;
    } on ServerLoginRequiredException {
      // The server answered; it just wants a re-login.  Never permanent.
      return _Outcome.needsLogin;
    } on DioException catch (e) {
      final attempts = intent.attempts + 1;
      return isPermanentFailure(e.response?.statusCode, attempts: attempts)
          ? _Outcome.permanent
          : _Outcome.transient;
    } catch (e) {
      // Non-HTTP failure (a parse error, say).  Charge it to the retry budget
      // rather than throwing the user's edit away.
      CacheLogger.logError('outbox replay', e);
      final attempts = intent.attempts + 1;
      return isPermanentFailure(null, attempts: attempts)
          ? _Outcome.permanent
          : _Outcome.transient;
    }
  }

  Future<void> _replayTermEdit(TermEditIntent intent) async {
    final Map<String, dynamic> payload;
    if (intent.formData != null) {
      // The snapshot carries the fields the user did not touch, but `status`
      // comes from the intent: a later double-tap coalesces onto this intent
      // and changes only the status, so the snapshot's own status is stale.
      payload = {...intent.formData!, 'status': intent.status};
    } else {
      // A bare status cycle.  `/read/edit_term/<id>` submits a *whole* term,
      // so the current form has to be fetched first or the POST would blank
      // the term's translation, tags and image.
      final form = await _content.getTermFormById(
        intent.termId,
        bypassQueue: true,
      );
      payload = form.copyWith(status: intent.status).toFormData();
    }
    await _content.editTerm(intent.termId, payload, bypassQueue: true);
  }

  Future<void> _replayPageDone(PageDoneIntent intent) async {
    // `restknown=1` is a superset of `restknown=0`: `mark_page_read` records
    // the read date and the words-read row either way, and only the
    // unknowns-to-known step is conditional.  So one call covers both flags,
    // and sending the superset can never lose the All Known the user asked
    // for.
    if (intent.markKnown) {
      await _content.markPageKnownOnly(
        intent.bookId,
        intent.pageNum,
        bypassQueue: true,
      );
    } else if (intent.markRead) {
      await _content.markPageReadOnly(
        intent.bookId,
        intent.pageNum,
        bypassQueue: true,
      );
    }
  }

  Future<void> _markFailed(PendingIntent intent) async {
    final failed = intent.asFailed();
    _intents[intent.coalesceKey] = failed;
    await _write(failed);
    onChanged?.call();
  }

  Future<void> _backOff(PendingIntent intent) async {
    final attempts = intent.attempts + 1;
    final retryAt =
        DateTime.now().millisecondsSinceEpoch +
        nextRetryDelay(attempts).inMilliseconds;

    final backedOff = intent.withRetry(
      attempts: attempts,
      nextAttemptAtMs: retryAt,
    );
    _intents[intent.coalesceKey] = backedOff;
    await _write(backedOff);
  }

  Future<void> _write(PendingIntent intent) async {
    try {
      await _store.write(intent.coalesceKey, intent.encode());
    } catch (e) {
      // A payload that will not serialise must not take the app down: the
      // in-memory copy still lets the flush try.
      CacheLogger.logError('outbox write', e);
    }
  }
}
