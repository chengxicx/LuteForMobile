import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/local_books/providers/local_book_providers.dart';
import '../../../shared/providers/network_providers.dart';
import '../services/epub_local_server.dart';
import '../services/epub_offline_prefetch.dart';
import '../services/epub_offline_store.dart';

/// Disk store for the EPUB offline packs (app cache directory).
final epubOfflineStoreProvider = Provider<EpubOfflineStore>((ref) {
  return EpubOfflineStore();
});

/// The loopback server that serves the packs to the reader WebView.
///
/// Never created on web builds: dart:io HttpServer does not exist there
/// and the PWA reads online-only anyway.
final epubLocalServerProvider = Provider<EpubLocalServer?>((ref) {
  if (kIsWeb) return null;
  final bookStore = ref.watch(localBookStoreProvider);
  return EpubLocalServer(
    store: ref.watch(epubOfflineStoreProvider),
    localRootResolver: bookStore.root,
  );
});

/// Pack builder: full downloads (bookshelf button) and the
/// current/next-chapter background cache (reader).
final epubOfflinePrefetchProvider = Provider<EpubOfflinePrefetch>((ref) {
  return EpubOfflinePrefetch(
    apiService: ref.watch(apiServiceProvider),
    contentService: ref.watch(contentServiceProvider),
    store: ref.watch(epubOfflineStoreProvider),
  );
});
