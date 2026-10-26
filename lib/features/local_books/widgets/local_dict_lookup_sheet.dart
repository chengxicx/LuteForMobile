import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dict/dict_repository.dart';
import '../providers/local_book_providers.dart';
import '../services/local_book_store.dart';

/// Offline dictionary lookup for a locally imported book.
///
/// The word comes from the reading page's floating 查词 button (a text
/// selection or a tap-extended word); the lookup itself goes straight
/// to the on-device dictionary pool (`DictRepository.lookupInPool`),
/// so it works with zero connectivity -- the whole point of Phase 2.
/// The chosen dictionary is remembered per book (local books have no
/// server language id to hang a language-wide choice on).
class LocalDictLookupSheet extends ConsumerStatefulWidget {
  const LocalDictLookupSheet({
    super.key,
    required this.bookId,
    required this.initialTerm,
  });

  final String bookId;
  final String initialTerm;

  @override
  ConsumerState<LocalDictLookupSheet> createState() =>
      _LocalDictLookupSheetState();
}

class _LocalDictLookupSheetState extends ConsumerState<LocalDictLookupSheet> {
  late final TextEditingController _termController;
  List<PoolDict> _pool = const [];
  String? _selected;
  PoolLookupResult? _result;
  bool _loading = false;
  bool _poolLoaded = false;

  @override
  void initState() {
    super.initState();
    _termController = TextEditingController(text: widget.initialTerm);
    _loadPool();
  }

  @override
  void dispose() {
    _termController.dispose();
    super.dispose();
  }

  Future<void> _loadPool() async {
    final store = ref.read(localBookStoreProvider);
    final pool = await ref.read(dictRepositoryProvider).listPool();
    if (!mounted) return;

    String? selected;
    final record = await store.get(widget.bookId);
    if (record?.dictFilename != null &&
        pool.any((d) => d.filename == record!.dictFilename)) {
      selected = record!.dictFilename;
    } else if (pool.isNotEmpty) {
      selected = pool.first.filename;
    }

    setState(() {
      _pool = pool;
      _selected = selected;
      _poolLoaded = true;
    });
    if (selected != null) _lookup();
  }

  Future<void> _lookup() async {
    final term = _termController.text.trim();
    final filename = _selected;
    if (term.isEmpty || filename == null) return;
    setState(() => _loading = true);
    final result = await ref
        .read(dictRepositoryProvider)
        .lookupInPool(filename: filename, term: term);
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  Future<void> _changeDict(String? filename) async {
    if (filename == null || filename == _selected) return;
    setState(() {
      _selected = filename;
      _result = null;
    });
    await ref
        .read(localBookStoreProvider)
        .setDictFilename(widget.bookId, filename);
    _lookup();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _termController,
                  autofocus: widget.initialTerm.isEmpty,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _lookup(),
                  decoration: const InputDecoration(
                    labelText: 'Word',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Look up',
                onPressed: _lookup,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_poolLoaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else if (_pool.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No dictionary in the local pool. Import an .mdx in '
                'Settings → Local dictionary first.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else ...[
            DropdownButtonFormField<String>(
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Dictionary',
                isDense: true,
              ),
              items: _pool
                  .map(
                    (d) => DropdownMenuItem(
                      value: d.filename,
                      child: Text(
                        d.filename,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _changeDict,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.42,
              child: _resultArea(theme),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultArea(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final result = _result;
    if (result == null) {
      return Center(
        child: Text('Look up a word above.', style: theme.textTheme.bodySmall),
      );
    }
    if (!result.available) {
      return Center(
        child: Text(
          'This dictionary is not usable on this device.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final gloss = result.gloss;
    if (gloss == null || gloss.isEmpty) {
      return Center(
        child: Text(
          'No entry for this word.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return SingleChildScrollView(
      child: SelectableText(
        gloss,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
    );
  }
}

/// Shows the lookup sheet for [term]; the caller decides the wording of
/// the surrounding UX, this only owns the sheet itself.
Future<void> showLocalDictLookupSheet(
  BuildContext context, {
  required String bookId,
  required String term,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => LocalDictLookupSheet(bookId: bookId, initialTerm: term),
  );
}
