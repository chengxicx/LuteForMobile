// Contract tests for the reader's furigana switch.
//
// `templates/read/index.html` renders, on every reading page:
//
//     var LUTE_FURIGANA = { enabled: <bool>, langId: <int> };
//
// and both metadata endpoints the app fetches (`/read/<id>` and
// `/read/<id>/page/<n>`) render that template -- so this block is the only
// place the language id can come from.  The app reads `langId` alone: its
// own "show furigana" setting is deliberately independent of the language's
// web toggle, so `enabled` must not gate anything on this side.  A null
// langId (an older server) is also the signal to leave the page layout
// untouched, which is why the "no block" case matters.
//
// 运行：flutter test test/furigana_parse_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';

/// The page body is irrelevant here; only the metadata block is under test.
const String _textHtml = '<div id="thetext"></div>';

String _metadataHtml(String scriptBody) {
  return '''
<script type="text/javascript">
  var LUTE_SENTENCE_LOOKUP_DICTS = [];
  var LUTE_BOOK_TYPE = "text";
$scriptBody
</script>
''';
}

PageData _parse(String scriptBody) {
  final parser = HtmlParser();
  return parser.parsePage(_textHtml, _metadataHtml(scriptBody), bookId: 7);
}

void main() {
  test('langId reaches PageData', () {
    final page = _parse('  var LUTE_FURIGANA = { enabled: false, langId: 9 };');

    expect(page.furiganaLangId, 9);
  });

  test('enabled:true parses identically (the flag is deliberately ignored)', () {
    final page = _parse('  var LUTE_FURIGANA = { enabled: true, langId: 4 };');

    expect(
      page.furiganaLangId,
      4,
      reason: 'the app has its own switch; the server flag must not gate it',
    );
  });

  test('reads the LUTE_FURIGANA object, not a neighbouring one', () {
    final page = _parse('''
  var LUTE_TERM_FILL = { source: "online", langId: 3 };
  var LUTE_FURIGANA = { enabled: true, langId: 11 };
''');

    expect(page.furiganaLangId, 11);
  });

  test('a server without the block yields null (layout stays as-is)', () {
    final page = _parse('  var LUTE_BOOK_TYPE = "text";');

    expect(page.furiganaLangId, isNull);
  });

  test('the text document is searched as a fallback', () {
    final parser = HtmlParser();
    final page = parser.parsePage(
      '<script>var LUTE_FURIGANA = { enabled: true, langId: 6 };</script>'
      '<div id="thetext"></div>',
      '<script>var LUTE_BOOK_TYPE = "text";</script>',
      bookId: 7,
    );

    expect(page.furiganaLangId, 6);
  });

  test('copyWith keeps the language id when it is not overridden', () {
    final page = _parse('  var LUTE_FURIGANA = { enabled: true, langId: 9 };');

    expect(page.copyWith(currentPage: 3).furiganaLangId, 9);
  });
}
