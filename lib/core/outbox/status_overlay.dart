import '../../features/reader/models/manga_page.dart';
import '../../features/reader/models/page_data.dart';
import '../../features/reader/models/paragraph.dart';
import '../../features/reader/models/pdf_page.dart';
import '../../features/reader/models/text_item.dart';
import 'models/pending_intent.dart';

/// The statuses the user has set that have not reached the server yet.
///
/// Failed intents are deliberately **included**: a failed intent is still
/// something the user asked for, and it stays in the outbox precisely so they
/// can retry or discard it.  Dropping the colour while it sits there would
/// silently revert their edit and hide the fact that it needs attention.
Map<int, String> pendingStatusByTermId(Iterable<PendingIntent> intents) {
  final result = <int, String>{};
  for (final intent in intents) {
    if (intent is TermEditIntent) {
      // Later intents overwrite earlier ones, but coalescing already
      // guarantees at most one intent per term.
      result[intent.termId] = intent.status;
    }
  }
  return result;
}

/// Return [page] with every pending status painted over it.
///
/// This is the piece that makes offline editing actually *stick* on screen.
/// `_mergePageStatuses` overwrites each item's `statusClass` with the server's
/// on every background refresh, so without this overlay a word edited in the
/// subway flips back to its old colour the moment the page refreshes — before
/// the outbox has had any chance to sync.
///
/// Must run **after** `parsePage` and after any merge, immediately before the
/// value is handed to `state`.  Applying it earlier (on raw HTML, say) is a
/// no-op.
PageData applyPendingStatuses(PageData page, Map<int, String> pending) {
  if (pending.isEmpty) return page;

  final paragraphs = <Paragraph>[];
  for (final paragraph in page.paragraphs) {
    final overlaid = _overlayItems(paragraph.textItems, pending);
    paragraphs.add(
      identical(overlaid, paragraph.textItems)
          ? paragraph
          : paragraph.copyWith(textItems: overlaid),
    );
  }

  return page.copyWith(
    paragraphs: paragraphs,
    // copyWith keeps the original when these come back null, so a text book
    // is untouched by the manga/pdf work.
    mangaPage: _overlayManga(page.mangaPage, pending),
    pdfPage: _overlayPdf(page.pdfPage, pending),
  );
}

/// Whether [bookId]/[pageNum] still owes the server an "All Known" mark.
///
/// `restknown=1` is the only thing that flips a page's unknown words, and the
/// outbox coalesces those marks per page, so at most one intent can match.
bool hasPendingPageKnown(
  Iterable<PendingIntent> intents,
  int bookId,
  int pageNum,
) {
  for (final intent in intents) {
    if (intent is PageDoneIntent &&
        intent.markKnown &&
        intent.bookId == bookId &&
        intent.pageNum == pageNum) {
      return true;
    }
  }
  return false;
}

/// Every word on [page] that is still unknown, mapped to status 99.
///
/// This is the exact set the server's `set_unknowns_to_known` would flip: it
/// selects on `term.status == 0`, so a word the user explicitly set to
/// 1..5/98 is not in here and is left alone -- matching the server.
Map<int, String> unknownWordStatuses(PageData page) {
  final unknowns = <int, String>{};

  void collect(List<TextItem> items) {
    for (final item in items) {
      final wordId = item.wordId;
      if (wordId != null && item.isUnknown) unknowns[wordId] = '99';
    }
  }

  for (final paragraph in page.paragraphs) {
    collect(paragraph.textItems);
  }
  for (final block in page.mangaPage?.blocks ?? const <MangaBlock>[]) {
    for (final line in block.lineItems) {
      collect(line);
    }
  }
  for (final word in page.pdfPage?.words ?? const <PdfWord>[]) {
    collect(word.items);
  }

  return unknowns;
}

/// [page] with every unknown word shown as known.
///
/// The optimistic half of the "All Known" button: the server cannot confirm
/// anything while the device is offline, but the user pressed the button and
/// the page they are looking at should agree with what they asked for.
PageData applyPageKnown(PageData page) =>
    applyPendingStatuses(page, unknownWordStatuses(page));

List<TextItem> _overlayItems(List<TextItem> items, Map<int, String> pending) {
  List<TextItem>? result;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final wordId = item.wordId;
    final status = wordId == null ? null : pending[wordId];
    if (status == null) {
      result?.add(item);
      continue;
    }

    final statusClass = 'status$status';
    if (statusClass == item.statusClass) {
      result?.add(item);
      continue;
    }

    // Allocate only once we know something actually changes: this runs on
    // every page load, and most pages carry no pending edits at all.
    result ??= items.sublist(0, i);
    result.add(item.copyWith(statusClass: statusClass));
  }
  return result ?? items;
}

MangaPageData? _overlayManga(MangaPageData? page, Map<int, String> pending) {
  if (page == null) return null;

  List<MangaBlock>? blocks;
  for (var i = 0; i < page.blocks.length; i++) {
    final block = page.blocks[i];

    List<List<TextItem>>? lineItems;
    for (var j = 0; j < block.lineItems.length; j++) {
      final line = block.lineItems[j];
      final overlaid = _overlayItems(line, pending);
      if (identical(overlaid, line)) {
        lineItems?.add(line);
        continue;
      }
      lineItems ??= block.lineItems.sublist(0, j);
      lineItems.add(overlaid);
    }

    if (lineItems == null) {
      blocks?.add(block);
      continue;
    }

    // MangaBlock is immutable with no copyWith, so rebuild it.
    blocks ??= page.blocks.sublist(0, i);
    blocks.add(
      MangaBlock(
        left: block.left,
        top: block.top,
        width: block.width,
        height: block.height,
        vertical: block.vertical,
        fontSizeCqw: block.fontSizeCqw,
        lineItems: lineItems,
      ),
    );
  }

  if (blocks == null) return page;
  return MangaPageData(
    imagePath: page.imagePath,
    imgWidth: page.imgWidth,
    imgHeight: page.imgHeight,
    pageNum: page.pageNum,
    blocks: blocks,
  );
}

PdfPageData? _overlayPdf(PdfPageData? page, Map<int, String> pending) {
  if (page == null) return null;

  List<PdfWord>? words;
  for (var i = 0; i < page.words.length; i++) {
    final word = page.words[i];
    final overlaid = _overlayItems(word.items, pending);
    if (identical(overlaid, word.items)) {
      words?.add(word);
      continue;
    }

    // PdfWord is immutable with no copyWith, so rebuild it.
    words ??= page.words.sublist(0, i);
    words.add(
      PdfWord(
        left: word.left,
        top: word.top,
        width: word.width,
        height: word.height,
        items: overlaid,
      ),
    );
  }

  if (words == null) return page;
  return PdfPageData(
    pdfPath: page.pdfPath,
    pageWidth: page.pageWidth,
    pageHeight: page.pageHeight,
    pageNum: page.pageNum,
    words: words,
  );
}
