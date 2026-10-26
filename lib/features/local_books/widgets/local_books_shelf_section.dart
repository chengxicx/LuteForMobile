import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../providers/local_book_providers.dart';
import '../services/local_book_store.dart';
import '../services/local_epub_page.dart' show localEpubPageVersion;
import 'local_book_reader_screen.dart';

/// The「本地书」strip on the bookshelf: locally imported EPUBs that read
/// entirely on-device (dictionary lookups included, offline).
///
/// A compact horizontal rail above the server shelf -- collapsed to
/// just its header when there are no local books yet, so the shelf
/// looks unchanged for anyone not using the feature.
class LocalBooksShelfSection extends ConsumerStatefulWidget {
  const LocalBooksShelfSection({super.key});

  @override
  ConsumerState<LocalBooksShelfSection> createState() =>
      _LocalBooksShelfSectionState();
}

class _LocalBooksShelfSectionState extends ConsumerState<LocalBooksShelfSection> {
  List<LocalBookRecord> _books = const [];
  bool _loading = true;
  bool _expanded = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final books = await ref.read(localBookStoreProvider).list();
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
      _expanded = books.isNotEmpty;
    });
  }

  Future<void> _importEpub() async {
    if (_importing) return;
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['epub'],
      );
    } catch (_) {
      result = null;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || path.isEmpty) return;

    setState(() => _importing = true);
    try {
      final data = await ref
          .read(localEpubImporterProvider)
          .importFromFile(path);
      await ref
          .read(localBookStoreProvider)
          .upsert(
            LocalBookRecord(
              id: data.id,
              title: data.title,
              author: data.author,
              chapterCount: data.chapters.length,
              pageVersion: localEpubPageVersion,
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported "${data.title}" '
              '(${data.chapters.length} chapters)'),
          action: SnackBarAction(
            label: 'Read',
            onPressed: () => _openReader(data.id),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Import failed: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _openReader(String id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalBookReaderScreen(bookId: id),
      ),
    );
  }

  Future<void> _delete(LocalBookRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete local book'),
        content: Text(
          'Delete "${record.title}" from this device? The .epub file and '
          'your local reading position are removed.'
          '${record.serverBookId != null ? ' The server copy stays.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: dialogContext.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(localBookStoreProvider).delete(record.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final books = _books;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: books.isEmpty ? null : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Icon(
                  Icons.smartphone,
                  size: 16,
                  color: context.appColorScheme.text.secondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Local books',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: context.appColorScheme.text.secondary,
                  ),
                ),
                if (books.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${books.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.appColorScheme.text.secondary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: context.appColorScheme.text.secondary,
                  ),
                ] else
                  ...[
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _importing ? null : _importEpub,
                      icon: _importing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 18),
                      label: const Text('Import local EPUB'),
                    ),
                  ],
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        if (_expanded && books.isNotEmpty)
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: books.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == books.length) {
                  return ActionChip(
                    avatar: _importing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add, size: 18),
                    label: const Text('Import'),
                    onPressed: _importing ? null : _importEpub,
                  );
                }
                final book = books[index];
                return _LocalBookChip(
                  book: book,
                  onTap: () => _openReader(book.id),
                  onLongPress: () => _delete(book),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _LocalBookChip extends StatelessWidget {
  const _LocalBookChip({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  final LocalBookRecord book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (book.serverBookId != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.cloud_done_outlined,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ],
            ),
            Text(
              '${book.chapterCount} chapters',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
