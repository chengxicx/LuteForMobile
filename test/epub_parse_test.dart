// Contract tests for the reader-mode EPUB fragment
// (`templates/read/epub_page.html` on the server).
//
// The fragment carries no .textsentence spans -- those are injected
// browser-side by lute-epub-reader.js, which the app never runs.  What the
// app parses out of it instead is the token stream
// (`#lute-epub-tokens`, `[text, wo_id, status, sentence, paragraph]`,
// wo_id 0 / status -1 for non-words), rebuilt into the same
// Paragraph/TextItem model a text page parses into, plus the chapter
// descriptor (stylesheet URLs, fixed-layout viewport).  These tests pin:
//
//   * token -> TextItem mapping: word ids, status classes, sentence
//     grouping (one Paragraph per sentence), sentence-start flags,
//     running order;
//   * non-word tokens (punctuation, spaces) get no word id and no status;
//   * Flask's htmlsafe tojson escaping (`&` -> `\u0026`) is decoded;
//   * a fixed-layout chapter (`data-epub-viewport`) flips fixedLayout and
//     carries its pixel viewport;
//   * every non-epub page still parses exactly as before (null chapter,
//     classic paragraphs).

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';

const String _metadataHtml = '<div></div>';

String _epubFragment({
  required String tokensJson,
  String bodyHtml = '<div class="epub-body"><p>Hello world. Second</p></div>',
}) {
  return '''
<div id="thetext" class="epub-text-container">
  <div id="epub-chapter"
       data-epub-css="/static/epub/abc/lute.css"
       data-epub-orig-css="/static/epub/abc/lute-orig.css">$bodyHtml</div>
</div>
<script type="application/json" id="lute-epub-tokens">$tokensJson</script>
<script type="application/json" id="lute-epub-substitutions">[]</script>
''';
}

void main() {
  test('tokens rebuild into paragraphs with statuses and word ids', () {
    // "R\\u0026D" is how Flask's htmlsafe |tojson renders "R&D".
    final page = HtmlParser().parsePage(
      _epubFragment(
        tokensJson:
            '[["Hello",1,0,1,1],[" ",0,-1,1,1],["world",2,1,1,1],'
            '[".",0,-1,1,1],["R\\u0026D",3,-1,2,1],["Second",4,-1,2,1]]',
      ),
      _metadataHtml,
      bookId: 7,
    );

    expect(page.epubChapter, isNotNull);
    expect(page.epubChapter!.cssUrl, '/static/epub/abc/lute.css');
    expect(page.epubChapter!.origCssUrl, '/static/epub/abc/lute-orig.css');
    expect(page.epubChapter!.fixedLayout, isFalse);

    // One mobile Paragraph per sentence, like the classic text parse.
    expect(page.paragraphs.length, 2);

    final sentence1 = page.paragraphs[0].textItems;
    expect(sentence1.map((i) => i.text).toList(), ['Hello', ' ', 'world', '.']);
    final hello = sentence1.first;
    expect(hello.wordId, 1);
    expect(hello.statusClass, 'status0');
    expect(hello.isStartOfSentence, isTrue);
    expect(hello.sentenceId, 1);
    expect(hello.paragraphId, 1);
    final world = sentence1.firstWhere((i) => i.text == 'world');
    expect(world.wordId, 2);
    expect(world.statusClass, 'status1');
    expect(world.isStartOfSentence, isFalse);

    // Non-words carry no word id and no status highlight.
    final space = sentence1.firstWhere((i) => i.text == ' ');
    expect(space.wordId, isNull);
    expect(space.statusClass, '');

    // Flask's \u0026 escaping is decoded back to the real character.
    final amp = page.paragraphs[1].textItems.first;
    expect(amp.text, 'R&D');

    // A word token with status -1 (no status yet) reads as unknown, the
    // same class the server saves it under on first render.
    expect(amp.statusClass, 'status0');
    final second = page.paragraphs[1].textItems[1];
    expect(second.sentenceId, 2);
    expect(second.isStartOfSentence, isFalse);

    // Orders are unique and page-wide, like the text page's data-order.
    final orders = page.paragraphs
        .expand((p) => p.textItems)
        .map((i) => i.order)
        .toSet();
    expect(orders.length, 6);
  });

  test('a fixed-layout chapter carries its pixel viewport', () {
    final page = HtmlParser().parsePage(
      _epubFragment(
        tokensJson: '[["Pic",1,0,1,1]]',
        bodyHtml:
            '<div class="epub-body epub-fixed" data-epub-viewport="800x600">'
            '<p>Picture book page</p></div>',
      ),
      _metadataHtml,
      bookId: 8,
    );

    expect(page.epubChapter, isNotNull);
    expect(page.epubChapter!.fixedLayout, isTrue);
    expect(page.epubChapter!.viewportWidth, 800);
    expect(page.epubChapter!.viewportHeight, 600);
  });

  test('a broken token stream degrades to an empty-but-usable page', () {
    final page = HtmlParser().parsePage(
      _epubFragment(tokensJson: 'not json at all'),
      _metadataHtml,
      bookId: 9,
    );

    // The chapter descriptor still switches the reader to the WebView,
    // which mounts from its own copy of the tokens; the native paragraphs
    // are simply empty until the next successful parse.
    expect(page.epubChapter, isNotNull);
    expect(page.paragraphs, isEmpty);
  });

  test('non-epub pages are untouched', () {
    final page = HtmlParser().parsePage(
      '''
<div id="thetext"><p>
  <span class="textsentence"><span class="textitem" data-text="Hi"
        data-status-class="status1" data-wid="5" data-order="0"
        data-sentence-id="1" data-paragraph-id="1">Hi</span></span>
</p></div>
''',
      _metadataHtml,
      bookId: 10,
    );

    expect(page.epubChapter, isNull);
    expect(page.paragraphs.length, 1);
    expect(page.paragraphs[0].textItems.single.wordId, 5);
    expect(page.paragraphs[0].textItems.single.statusClass, 'status1');
  });
}
