import 'package:flutter_riverpod/flutter_riverpod.dart';

final initialServerUrlProvider = Provider<String>((ref) => '');

/// Outbox entries read from disk before `runApp`, keyed by coalesce key.
///
/// Injected the same way as [initialServerUrlProvider] so the very first frame
/// can already paint pending (unsynced) term statuses, instead of showing the
/// stale server colour for a frame and then flipping.
final initialOutboxEntriesProvider = Provider<Map<String, String>>(
  (ref) => const {},
);
