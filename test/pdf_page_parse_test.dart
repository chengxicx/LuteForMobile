// PDF 页数据契约测试（手机端 PDF 渲染的数据根）。
//
// pdf 页的 HTML（服务端 read/pdf_page.html）没有 .textsentence 包裹，
// parsePage 出来的 paragraphs 恒为空 —— 与 manga 页一样，正文数据在
// pdfPage.words 上。词框坐标是页面百分比（服务端 pypdf 估算），词内的
// token 与文本页同构（span[data-text]），所以词点击/查词链路能直接复用。
//
//   1. pdf 页 paragraphs 为空、pdfPage.words 有数据；
//   2. data-pdf-url / page 尺寸 / 词框百分比正确落位；
//   3. 词内多个 token 依序解析，langId/status/wordId 不丢；
//   4. 普通文本页 pdfPage 为 null。
//
// 运行：flutter test test/pdf_page_parse_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';

const _pdfPageHtml = '''
<div class="pdf-page" data-pdf-url="/static/pdf/x/book.pdf"
     data-page-num="3" data-page-width="612" data-page-height="792">
  <canvas class="pdf-page-canvas"></canvas>
  <div class="pdf-word" style="left: 10.000%; top: 5.000%; width: 12.345%; height: 2.000%;">
    <span class="pdf-word-seg" style="flex: 2 1 0px;">
      <span id="ti0" class="textitem status0" data-lang-id="7"
            data-paragraph-id="0" data-sentence-id="0" data-text="世界"
            data-status-class="status0" data-order="0" data-wid="42">世界</span>
    </span>
    <span class="pdf-word-seg" style="flex: 1 1 0px;">
      <span id="ti1" class="textitem status1" data-lang-id="7"
            data-paragraph-id="0" data-sentence-id="0" data-text="だ"
            data-status-class="status1" data-order="1" data-wid="43">だ</span>
    </span>
  </div>
</div>
''';

const _metadataHtml = '''
<input id="page_num" value="3" />
<input id="page_count" value="100" />
<div id="thetexttitle">PDF test</div>
''';

const _textPageHtml = '''
<div id="thetext">
  <p class="textsentence">
    <span class="textitem status0" data-text="Hello" data-wid="1">Hello</span>
  </p>
</div>
''';

void main() {
  test('pdf 页 paragraphs 为空，正文在 pdfPage.words 上', () {
    final pageData = HtmlParser().parsePage(
      _pdfPageHtml,
      _metadataHtml,
      bookId: 1,
    );

    final pdfPage = pageData.pdfPage;
    expect(pdfPage, isNotNull);

    // 没有 .textsentence：段落列表是空的（与 manga 页同构）。
    expect(pageData.paragraphs, isEmpty);

    expect(pdfPage!.pdfPath, '/static/pdf/x/book.pdf');
    expect(pdfPage.pageWidth, 612);
    expect(pdfPage.pageHeight, 792);
    expect(pdfPage.pageNum, 3);
  });

  test('词框百分比与词内 token 解析正确', () {
    final pdfPage = HtmlParser()
        .parsePage(_pdfPageHtml, _metadataHtml, bookId: 1)
        .pdfPage!;

    final word = pdfPage.words.single;
    expect(word.left, 10.0);
    expect(word.top, 5.0);
    expect(word.width, closeTo(12.345, 1e-9));
    expect(word.height, 2.0);

    expect(word.items, hasLength(2));
    expect(word.items[0].text, '世界');
    expect(word.items[0].statusClass, 'status0');
    expect(word.items[0].wordId, 42);
    expect(word.items[0].langId, 7);
    expect(word.items[1].text, 'だ');
    expect(word.items[1].statusClass, 'status1');
    expect(word.items[1].order, 1);
  });

  test('普通文本页 pdfPage 为 null', () {
    final pageData = HtmlParser().parsePage(
      _textPageHtml,
      _metadataHtml,
      bookId: 1,
    );
    expect(pageData.pdfPage, isNull);
    expect(pageData.paragraphs, isNotEmpty);
  });
}
