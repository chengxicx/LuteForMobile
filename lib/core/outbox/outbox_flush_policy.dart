import 'models/pending_intent.dart';

/// Pure decisions for the flush loop.
///
/// Split out from the service so the retry/backoff/give-up rules can be
/// asserted exhaustively with no store, no network and no provider container.

/// Backoff cap.  Five minutes is long enough not to hammer a flaky link and
/// short enough that a synced-out edit still lands while the user is reading.
const int maxRetrySeconds = 300;

/// How many transient failures before an intent is declared permanently failed.
const int maxFlushAttempts = 10;

/// Intents that may be sent right now, in the order they should go out.
///
/// `seq` ascending, not newest-first: the user's actions have a causal order
/// (they set a status, then changed their mind), and replaying out of order
/// would apply the earlier intent last.
List<PendingIntent> planFlush(
  Iterable<PendingIntent> intents, {
  required int nowMs,
  int limit = 50,
}) {
  final eligible =
      intents
          .where((intent) => !intent.failed && intent.nextAttemptAtMs <= nowMs)
          .toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));

  if (eligible.length <= limit) return eligible;
  return eligible.sublist(0, limit);
}

/// Exponential backoff, clamped so it never overflows and never exceeds
/// [maxRetrySeconds].  Monotonically non-decreasing in `attempts`.
Duration nextRetryDelay(int attempts) {
  // Clamped before the shift: `1 << 30` on a large attempt count is how this
  // turns into a negative or absurd duration.
  final safeAttempts = attempts < 0 ? 0 : (attempts > 8 ? 8 : attempts);
  final seconds = 5 * (1 << safeAttempts);
  return Duration(seconds: seconds > maxRetrySeconds ? maxRetrySeconds : seconds);
}

/// Whether a failure should retire the intent instead of retrying it.
///
/// A null [statusCode] means the request never got an HTTP answer (timeout,
/// connection error, DNS) — that is the transient case, so it is *not*
/// permanent.  Session expiry is handled by the caller, not here: a re-login
/// must resume the outbox rather than discard the user's edits.
bool isPermanentFailure(
  int? statusCode, {
  required int attempts,
  int maxAttempts = maxFlushAttempts,
}) {
  if (attempts >= maxAttempts) return true;
  if (statusCode == null) return false;

  switch (statusCode) {
    case 400: // malformed — replaying cannot fix it
    case 403: // forbidden
    case 404: // the term / book is gone
    case 410: // explicitly gone
    case 422: // the server rejected the payload
      return true;
    default:
      return false;
  }
}
