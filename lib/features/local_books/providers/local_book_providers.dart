import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_book_store.dart';
import '../services/local_epub_import.dart';

/// Shelf records + progress for locally imported books.
final localBookStoreProvider = Provider<LocalBookStore>((ref) {
  return LocalBookStore();
});

/// The on-device epub importer.  The book id is generated inside the
/// import, so nothing else needs seeding here.
final localEpubImporterProvider = Provider<LocalEpubImporter>((ref) {
  final store = ref.watch(localBookStoreProvider);
  return LocalEpubImporter(resolveRoot: store.root);
});
