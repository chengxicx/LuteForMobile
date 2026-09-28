import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/network_providers.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../../../features/reader/providers/reader_provider.dart';
import '../../providers/initial_providers.dart';
import '../outbox_service.dart';
import '../outbox_store.dart';
// Prefixed: the module-level helper and this notifier's getter would
// otherwise share a name.
import '../status_overlay.dart' as overlay;

/// The durable store.  Overridden in `main` with the instance that already
/// read the box, so the service can be seeded synchronously.
final outboxStoreProvider = Provider<OutboxStore>((ref) => HiveOutboxStore());

final outboxServiceProvider = Provider<OutboxService>((ref) {
  final service = OutboxService(
    store: ref.watch(outboxStoreProvider),
    content: ref.watch(contentServiceProvider),
  );

  // Seeded from the pre-`runApp` read: see [initialOutboxEntriesProvider].
  service.seed(ref.watch(initialOutboxEntriesProvider));

  return service;
});

/// How often to retry while something is still owed to the server.
///
/// This timer is the *primary* trigger, not a fallback, and it deliberately
/// does not ask `ServerStatusManager` for permission: that flag is a
/// best-effort hint for the UI, whereas the outbox holds the user's edits and
/// cannot delegate its own liveness to it.  When the flag was stuck false --
/// which is exactly what happens once page content and the outbox stop
/// feeding `ApiRequestQueue`, since that queue's probe is the only thing that
/// ever clears it -- a gated timer meant the flush never ran at all.
///
/// The rate is governed by each intent's own backoff (`planFlush` skips
/// anything not yet due), so a dead network costs one attempt per intent per
/// backoff window rather than one per tick.
const Duration _outboxRetryInterval = Duration(seconds: 30);

final outboxProvider = NotifierProvider<OutboxNotifier, OutboxState>(
  OutboxNotifier.new,
);

class OutboxNotifier extends Notifier<OutboxState> {
  Timer? _retryTimer;

  OutboxService get service => ref.read(outboxServiceProvider);

  @override
  OutboxState build() {
    final service = ref.watch(outboxServiceProvider);

    void publish() {
      state = OutboxState(
        intents: service.intents,
        isSyncing: service.isFlushing,
      );
    }

    service.onChanged = publish;

    // Once an edit actually lands, the server is authoritative again and the
    // optimistic overlay stops applying -- so every cache still holding the
    // pre-sync copy has to go, or the next read resurrects the old status.
    //
    // Registered from here rather than from the reader screen because the
    // invalidation must also run when that screen was never opened.  Reading
    // the reader notifier creates it if absent, which is free: its `build`
    // is a `const ReaderState()` with no I/O.
    service.onSent = (sent) {
      unawaited(ref.read(readerProvider.notifier).handleOutboxSynced(sent));
    };

    // Coming back online is the moment worth acting on: flush immediately
    // rather than waiting out the retry interval.
    void onReachabilityChanged() {
      if (ServerStatusManager.isReachable) unawaited(service.flush());
    }

    ServerStatusManager.addListener(onReachabilityChanged);

    _retryTimer = Timer.periodic(_outboxRetryInterval, (_) {
      if (service.intents.isEmpty) return;
      // No reachability check on purpose: see [_outboxRetryInterval].  A
      // wasted attempt against a dead link is cheap -- `planFlush` skips
      // anything still inside its backoff window -- and the attempt doubles
      // as the probe that puts `ServerStatusManager` back to reachable, so a
      // successful replay is what un-sticks the rest of the app.
      unawaited(service.flush());
    });

    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
      ServerStatusManager.removeListener(onReachabilityChanged);
      service.onChanged = null;
      service.onSent = null;
    });

    return OutboxState(intents: service.intents);
  }

  /// Statuses that have not reached the server yet, keyed by term id.
  ///
  /// Read this when building a page so pending edits win over the server's
  /// copy; see `applyPendingStatuses`.
  Map<int, String> get pendingStatusByTermId =>
      overlay.pendingStatusByTermId(state.intents);

  Future<void> enqueueTermStatus(
    int termId,
    String status, {
    int? langId,
    Map<String, dynamic>? formData,
  }) {
    return service.enqueueTermStatus(
      termId,
      status,
      langId: langId,
      formData: formData,
    );
  }

  Future<void> enqueueTermCreate(
    int langId,
    String text,
    Map<String, dynamic> formData,
  ) {
    return service.enqueueTermCreate(langId, text, formData);
  }

  Future<void> enqueuePageDone({
    required int bookId,
    required int pageNum,
    bool markRead = false,
    bool markKnown = false,
  }) {
    return service.enqueuePageDone(
      bookId: bookId,
      pageNum: pageNum,
      markRead: markRead,
      markKnown: markKnown,
    );
  }

  Future<void> flush() => service.flush();

  Future<void> retry(String coalesceKey) async {
    await service.retry(coalesceKey);
    unawaited(service.flush());
  }

  Future<void> discard(String coalesceKey) => service.discard(coalesceKey);

  Future<void> clearAll() => service.clearAll();
}
