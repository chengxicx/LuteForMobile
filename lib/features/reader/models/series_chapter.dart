import '../../books/models/book.dart';

/// One chapter of a book set, as the reader's Contents sheet lists it.
///
/// An EPUB import writes one Lute book per chapter, so "the chapter list"
/// is the member list of the series tag: [book] is that member, and
/// [position] is its 1-based place in the server's own chapter order.
class SeriesChapter {
  const SeriesChapter({
    required this.book,
    required this.title,
    required this.position,
  });

  final Book book;

  /// The chapter's own title, with the import's book-title prefix
  /// stripped (see [chapterDisplayTitle]).
  final String title;

  /// 1-based position in the set, i.e. the number the reader shows.
  final int position;

  int get bookId => book.id;
}

/// A chapter's title, without the prefix the import put in front of it.
///
/// `lute/book/epub_parser.py: chapter_book_title` names each chapter's book
/// `"<volume title> <NN> - <chapter title>"` -- `The Wife Between Us 05 -
/// Prologue` -- which is what keeps the series page in chapter order.  The
/// sheet only wants `Prologue`.
///
/// A title that does not carry that shape (a hand-made book set, a plain
/// tag whose books were uploaded one by one) is returned untouched: there
/// is nothing to strip, and guessing would eat real title text.  The
/// split is on the *first* `" NN - "`, so a chapter whose own title
/// contains " - " keeps the rest of it.
String chapterDisplayTitle(String fullTitle) {
  final title = fullTitle.trim();
  final match = RegExp(r'^.+?\s\d{1,4}\s-\s(.+)$').firstMatch(title);
  if (match == null) return title;
  final own = (match.group(1) ?? '').trim();
  return own.isEmpty ? title : own;
}

/// Chapter order for a book set: digit-aware, like the server's own.
///
/// `lute/book/series.py: _natural_title_key` re-sorts titles digit-by-digit
/// so "Ep 2" lands before "Ep 10", and that is the order which decides the
/// server's prev/next (`series_neighbours`).  The EPUB import zero-pads its
/// positions (`05`), which makes plain string order agree -- but a
/// hand-made set does not pad, and then lexicographic order would put
/// chapter 10 in front of chapter 2.
List<SeriesChapter> buildSeriesChapters(List<Book> books) {
  final sorted = [...books]..sort((a, b) => naturalCompare(a.title, b.title));
  return [
    for (var i = 0; i < sorted.length; i++)
      SeriesChapter(
        book: sorted[i],
        title: chapterDisplayTitle(sorted[i].title),
        position: i + 1,
      ),
  ];
}

/// Compare two strings treating digit runs as numbers.
int naturalCompare(String a, String b) {
  final left = _tokens(a);
  final right = _tokens(b);
  for (var i = 0; i < left.length && i < right.length; i++) {
    final l = left[i];
    final r = right[i];
    final ln = int.tryParse(l);
    final rn = int.tryParse(r);
    final int cmp;
    if (ln != null && rn != null) {
      cmp = ln.compareTo(rn);
    } else {
      cmp = l.toLowerCase().compareTo(r.toLowerCase());
    }
    if (cmp != 0) return cmp;
  }
  return left.length.compareTo(right.length);
}

/// Alternates non-digit / digit runs: `"Ep 10"` -> `["Ep ", "10"]`.
List<String> _tokens(String text) {
  final tokens = <String>[];
  var last = 0;
  for (final match in RegExp(r'\d+').allMatches(text)) {
    if (match.start > last) tokens.add(text.substring(last, match.start));
    tokens.add(match.group(0)!);
    last = match.end;
  }
  if (last < text.length) tokens.add(text.substring(last));
  return tokens;
}
