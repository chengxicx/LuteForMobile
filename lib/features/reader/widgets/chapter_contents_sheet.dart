import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/series_chapter.dart';
import '../providers/series_chapters_provider.dart';

/// The chapter list of the book set being read ("Contents").
///
/// Reached from the end-of-chapter block, so it opens on top of the reader
/// rather than replacing it: the reader keeps its scroll position, its
/// player and its word state, and closing the sheet puts the reader back
/// exactly where it was.
///
/// Deliberately flat -- square corners, hairline separators, one filled bar
/// for "you are here", no ripple, no shadow.  On the Leaf 5C the sheet is
/// the reader's second-most-used surface, and every rounded corner and
/// Material animation costs a full-screen e-ink refresh.
Future<void> showChapterContentsSheet({
  required BuildContext context,
  required String tag,
  required int currentBookId,
  required ValueChanged<SeriesChapter> onSelect,
  required String title,
  required String loadingLabel,
  required String emptyLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Square by design; the default sheet paints a 28 px radius.
    shape: const RoundedRectangleBorder(),
    backgroundColor: Theme.of(context).colorScheme.surface,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.72,
    ),
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chapters = ref.watch(seriesChaptersProvider(tag));
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        Widget body;
        if (chapters.isLoading && !chapters.hasValue) {
          body = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
            child: Text(
              loadingLabel,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          );
        } else {
          final items = chapters.asData?.value ?? const <SeriesChapter>[];
          if (items.isEmpty) {
            body = Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
              child: Text(
                emptyLabel,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            );
          } else {
            body = _ChapterList(
              items: items,
              currentBookId: currentBookId,
              onSelect: (chapter) {
                // Pop first: the reader is behind the sheet, and the
                // chapter it is about to load must not be covered by a
                // list of the chapter it just left.
                Navigator.of(sheetContext).pop();
                onSelect(chapter);
              },
            );
          }
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      iconSize: 20,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: scheme.outlineVariant),
              body,
            ],
          ),
        );
      },
    ),
  );
}

/// The scrolling list, opening near the chapter being read.
///
/// A 55-chapter volume would otherwise always open on chapter 1: the reader
/// arrives here from the *end* of a chapter, so the list has to start where
/// they are.  Rows are a fixed height, so the offset is arithmetic -- two
/// rows of context above the current chapter, and the scroll position clamps
/// it when the list is shorter than that.
class _ChapterList extends StatefulWidget {
  const _ChapterList({
    required this.items,
    required this.currentBookId,
    required this.onSelect,
  });

  final List<SeriesChapter> items;
  final int currentBookId;
  final ValueChanged<SeriesChapter> onSelect;

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: _initialOffset(),
  );

  double _initialOffset() {
    final index = widget.items.indexWhere(
      (chapter) => chapter.bookId == widget.currentBookId,
    );
    if (index <= 2) return 0;
    return (index - 2) * _ChapterRow.height;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: ListView.builder(
        controller: _controller,
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: widget.items.length,
        itemBuilder: (context, index) {
          final chapter = widget.items[index];
          return _ChapterRow(
            chapter: chapter,
            current: chapter.bookId == widget.currentBookId,
            onTap: () => widget.onSelect(chapter),
          );
        },
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.current,
    required this.onTap,
  });

  /// Fixed row height -- the list is positioned by arithmetic, not by a
  /// measured offset, so the two must stay in step.
  static const double height = 48;

  final SeriesChapter chapter;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final base = current
        ? textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          )
        : textTheme.bodyMedium?.copyWith(color: scheme.onSurface);

    return GestureDetector(
      // No ripple: an InkWell's splash is a full-row repaint per touch on
      // e-ink, and the row is tapped at most once.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: _ChapterRow.height,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            // "You are here" is a solid bar rather than a coloured row: on
            // a 16-grey e-ink panel a tinted row is indistinguishable from
            // the page behind it.
            Container(
              width: 3,
              color: current ? scheme.onSurface : Colors.transparent,
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 26,
              child: Text(
                '${chapter.position}',
                textAlign: TextAlign.right,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
