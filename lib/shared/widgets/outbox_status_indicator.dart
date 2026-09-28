import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/providers/outbox_provider.dart';

/// App-bar badge for edits that have not reached the server yet.
///
/// Renders **nothing** when the outbox is empty, so a reader with signal pays
/// nothing for this.  Ink-friendly by construction: a static glyph and a
/// count, never a spinner — on E-Ink a spinner is a full-screen refresh every
/// frame, which is the whole reason this widget exists in the app bar rather
/// than as an animated "syncing…" chip.
class OutboxStatusIndicator extends ConsumerWidget {
  const OutboxStatusIndicator({super.key, required this.serverReachable});

  /// Only affects the wording: "waiting for signal" vs "waiting to sync".
  final bool serverReachable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outbox = ref.watch(outboxProvider);
    if (outbox.isEmpty) return const SizedBox.shrink();

    final hasFailed = outbox.failedCount > 0;
    final theme = Theme.of(context);

    return Tooltip(
      message: hasFailed
          ? '${outbox.failedCount} edit(s) need attention'
          : '${outbox.pendingCount} edit(s) waiting to sync',
      child: InkWell(
        onTap: () => showOutboxDialog(context, serverReachable: serverReachable),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasFailed ? Icons.sync_problem : Icons.cloud_off,
                size: 20,
                color: hasFailed ? theme.colorScheme.error : null,
              ),
              const SizedBox(width: 4),
              Text('${outbox.intents.length}', style: theme.textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list behind the badge: what is queued, and what to do about it.
Future<void> showOutboxDialog(
  BuildContext context, {
  required bool serverReachable,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _OutboxDialog(serverReachable: serverReachable),
  );
}

class _OutboxDialog extends ConsumerWidget {
  const _OutboxDialog({required this.serverReachable});

  final bool serverReachable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outbox = ref.watch(outboxProvider);
    final notifier = ref.read(outboxProvider.notifier);
    final reachable = serverReachable;

    return AlertDialog(
      title: const Text('Pending edits'),
      content: SizedBox(
        width: 380,
        child: outbox.isEmpty
            ? const Text('Everything is synced.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reachable
                        ? 'These will be sent to the server now.'
                        : 'No connection. They are saved on this device and '
                              'will be sent as soon as there is signal.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  // Bounded height + shrinkWrap: a short queue sizes to its
                  // content, a long one scrolls instead of overflowing the
                  // dialog.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final intent in outbox.intents)
                          _OutboxTile(
                            intent: intent,
                            onRetry: () => notifier.retry(intent.coalesceKey),
                            onDiscard: () =>
                                notifier.discard(intent.coalesceKey),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        if (!outbox.isEmpty && reachable)
          TextButton(
            onPressed: () => notifier.flush(),
            child: const Text('Sync now'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _OutboxTile extends StatelessWidget {
  const _OutboxTile({
    required this.intent,
    required this.onRetry,
    required this.onDiscard,
  });

  final PendingIntent intent;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        intent.failed ? Icons.error_outline : Icons.schedule,
        color: intent.failed ? theme.colorScheme.error : null,
      ),
      title: Text(describeIntent(intent)),
      subtitle: intent.failed
          ? const Text('Failed. Retry, or discard to drop it.')
          : Text(
              intent.attempts == 0
                  ? 'Queued'
                  : 'Retrying (attempt ${intent.attempts + 1})',
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (intent.failed)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Discard this edit',
            onPressed: onDiscard,
          ),
        ],
      ),
    );
  }
}

/// One line a human can act on.  Ids are unavoidable for terms (the outbox
/// stores ids, not text), so the wording leads with the action, not the id.
String describeIntent(PendingIntent intent) => switch (intent) {
  TermEditIntent i => 'Set word #${i.termId} to status ${i.status}',
  TermCreateIntent i => 'Create the word "${i.text}"',
  PageDoneIntent i when i.markKnown =>
    'Mark book ${i.bookId} page ${i.pageNum} as all known',
  PageDoneIntent i => 'Mark book ${i.bookId} page ${i.pageNum} as read',
};
