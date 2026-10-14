import '../models/text_item.dart';

/// Pure-logic half of the reader's furigana support.
///
/// Kept free of Flutter and of the network so the batching / filtering rules
/// can be unit-tested on their own.  These rules mirror the web reader's
/// `lute/static/js/lute-furigana.js` one for one -- see the comments on each
/// piece for the corresponding line of JS.

/// Han characters, i.e. the characters a reading exists to explain.
///
/// The same three ranges the web reader tests (`has_kanji`): CJK Unified
/// Ideographs Extension A, the main CJK Unified Ideographs block, and the
/// CJK Compatibility Ideographs.  Kana, hangul and Latin are deliberately
/// absent -- they already read as their own pronunciation.
final RegExp _hanPattern = RegExp(
  r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]',
);

/// Thai characters -- the script a reading exists to explain when the
/// page's `LUTE_FURIGANA.script` is "thai".  The same range the web
/// reader tests (`has_thai`).
final RegExp _thaiPattern = RegExp(r'[\u0e00-\u0e7f]');

/// Whether [text] contains a character that needs a reading above it.
bool hasKanji(String text) => _hanPattern.hasMatch(text);

/// Whether [text] contains a Thai character.
bool hasThai(String text) => _thaiPattern.hasMatch(text);

/// Whether [text] needs a reading under [script] -- the web reader's
/// `needs_reading` (lute-furigana.js): every Thai word when the script is
/// "thai" (the script shows no pronunciation of its own), only
/// Han-bearing words otherwise (kana, hangul and Latin already show
/// their own pronunciation).  A null script -- a server predating the
/// field -- selects the "han" rule, same as the web.
bool _needsReading(String text, String? script) =>
    script == 'thai' ? hasThai(text) : hasKanji(text);

/// One readings request: a paragraph's word tokens plus the context text
/// they are read in.
class FuriganaBatch {
  /// The word cells this batch annotates, in document order.
  final List<TextItem> items;

  /// `items.map((i) => i.text)` -- the raw parser tokens, zero-width spaces
  /// and all, matching the web reader's `sp.dataset.text`.  The server's
  /// response is positionally parallel to this list.
  final List<String> tokens;

  /// The context the server parses each token in, so a morpheme is read in
  /// its sentence rather than in isolation (一つ -> ひとつ).
  ///
  /// The web reader builds this as `tokens.join("")` -- word tokens only,
  /// punctuation excluded -- and we match that exactly.  When the tokens
  /// cannot be re-aligned inside this text the server falls back to reading
  /// each token on its own, so the choice cannot make a reading *worse*
  /// than the per-token path.
  final String fullText;

  FuriganaBatch({
    required this.items,
    required this.tokens,
    required this.fullText,
  });
}

/// Whether this page is worth asking for readings at all.
///
/// Only languages that can supply readings (Japanese, Mandarin, Cantonese,
/// Thai) are written in a script whose pronunciation is hidden, so a page
/// whose word cells contain none of that script can be skipped outright.
/// That keeps the app's default-on setting from firing a request per
/// paragraph on every Latin / Cyrillic / hangul book.  Which script counts
/// is the page's `LUTE_FURIGANA.script` (see [_needsReading]); a null
/// script keeps the Han-only rule.
bool pageNeedsReadings(Iterable<TextItem> items, {String? script}) {
  for (final item in items) {
    if (item.wordId != null && _needsReading(item.text, script)) return true;
  }
  return false;
}

/// Groups the page's word cells into one batch per paragraph.
///
/// Mirrors `annotate()`: only the word cells participate (the web reader's
/// `span.word`, here `wordId != null`), and they are grouped by the server's
/// paragraph id (`data-paragraph-id`) so each request carries a paragraph's
/// worth of sentence context -- the natural batch a page breaks into.
///
/// Note the app's `Paragraph` model is actually a *sentence* (the parser
/// groups spans by `.textsentence`), which is why grouping happens here on
/// `item.paragraphId` rather than on the model's own boundaries.
List<FuriganaBatch> buildFuriganaBatches(Iterable<TextItem> items) {
  final byParagraph = <int, List<TextItem>>{};
  for (final item in items) {
    if (item.wordId == null) continue;
    byParagraph.putIfAbsent(item.paragraphId, () => <TextItem>[]).add(item);
  }

  return byParagraph.values.map((group) {
    final tokens = group.map((i) => i.text).toList();
    return FuriganaBatch(
      items: group,
      tokens: tokens,
      fullText: tokens.join(),
    );
  }).toList();
}

/// Folds one batch's response into [out].
///
/// [readings] is positionally parallel to `batch.tokens` -- entry *i* is the
/// reading of the *i*th token, or null when the server had none.
///
/// A reading is stored only when it will actually be shown, applying the
/// same guards as the web reader's `wrap_ruby`: the reading must be
/// present, must differ from the word itself, and the word must need a
/// reading under the page's script (a Han character, or any Thai
/// character when the script is "thai").  A word whose reading equals its
/// text (a kana word read as itself) would just repeat the word above
/// itself.
void mergeBatchReadings(
  Map<String, String> out,
  FuriganaBatch batch,
  List<String?> readings, {
  String? script,
}) {
  for (var i = 0; i < batch.items.length; i++) {
    final reading = i < readings.length ? readings[i]?.trim() : null;
    if (reading == null || reading.isEmpty) continue;

    final item = batch.items[i];
    if (reading == item.text) continue;
    if (!_needsReading(item.text, script)) continue;

    out[item.renderKey] = reading;
  }
}
