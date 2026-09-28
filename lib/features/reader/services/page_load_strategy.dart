/// Pure decision logic for "how should this page load resolve?".
///
/// Kept free of Flutter / Riverpod / Hive imports on purpose: the whole
/// point is that this table can be asserted exhaustively in a plain unit
/// test, with no widget harness and no fakes.  The caller (ReaderNotifier)
/// does the I/O -- this file only says which I/O is worth doing.
library;

/// How a page load should be resolved.
enum PageLoadStrategy {
  /// The caller named a page (tap, stepper, cold-start restore).  Cache
  /// first, then the network -- the behaviour that already existed.
  explicitPage,

  /// Nothing is remembered for this book.  Go straight to the network:
  /// the server answers with both the page number and the page content.
  initialNetwork,

  /// A page is remembered for this book *and* it is on disk.  Render it
  /// immediately; the server corrects it via the background refresh.
  localCacheThenRefresh,

  /// A page is remembered but is not on disk.  Ask the server for that
  /// exact page rather than letting it pick (the server would otherwise
  /// return whatever it thinks the current page is).
  recordNetwork,

  /// Offline, with nothing usable locally.  Fail fast instead of hanging
  /// on the request queue's 15s safety timeout.
  offlineNoCache,
}

/// Decide how to load a page.
///
/// [requestedPage] is an explicit page number from the caller (null when
/// the caller just says "open this book").  [localPage] is the remembered
/// page for this book, or null when there is no record.  [localPageCached]
/// is whether that remembered page is actually on disk -- a record whose
/// page was evicted is worthless offline, which is why it is a separate
/// input rather than being folded into [localPage].
///
/// [serverReachable] comes from `ServerStatusManager.isReachable`, which
/// only flips false *after* a request has already failed.  So it is a
/// hint, never a guarantee: the `false` branches are an optimisation, and
/// the caller still needs the queue bypass to fail fast on the first
/// request after losing signal.  See `PageLoadStrategy.offlineNoCache`.
PageLoadStrategy resolvePageLoadStrategy({
  required int? requestedPage,
  required int? localPage,
  required bool localPageCached,
  required bool serverReachable,
}) {
  // An explicitly requested page always wins: the user (or the cold-start
  // restore) has already decided where to go, and second-guessing it with
  // a remembered page would fight the user.
  if (requestedPage != null) return PageLoadStrategy.explicitPage;

  // No record for this book: there is nothing local to prefer, so the
  // server has to tell us where to start.
  if (localPage == null) {
    return serverReachable
        ? PageLoadStrategy.initialNetwork
        : PageLoadStrategy.offlineNoCache;
  }

  // Remembered page that is on disk: this is the whole point of the
  // feature -- open instantly, let the server catch up in the background.
  if (localPageCached) return PageLoadStrategy.localCacheThenRefresh;

  // Remembered page that is *not* on disk.  Online we still honour it (it
  // is where the reader actually was); offline there is nothing to show.
  return serverReachable
      ? PageLoadStrategy.recordNetwork
      : PageLoadStrategy.offlineNoCache;
}
