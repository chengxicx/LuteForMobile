// 正文「多出一个字」的回归：`overlapped` 词元必须取页面实显文字。
//
// 服务端的多词词元重叠时（例如 `のか` 与 `かな` 共用同一个「か」），后一格
// 只画尾部 token，但 `data-text` 仍然是**整条**词元（`か\u200bな`）。App 原来
// 一律取 `data-text` 拼句子，于是正文比字幕多出共用的那个字 ——
// 书 1143「サヨナラ」第二句就是这样变成 `…愛したの**かか**な?` 而 SRT 是
// `…のかな?`：那一句的卡拉OK高亮永远匹配不上，整页朗读也会多念一个音。
//
// 服务器只在 `display_text != text` 时加 `overlapped`，此时 span 的文字节点
// 就是 `html_display_text`（`display_text` 去掉零宽空格），正是读者看到的字。
//
// 运行：flutter test test/overlapped_token_parse_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';

const _metadataHtml = '''
<input id="page_num" value="1" />
<input id="page_count" value="2" />
<div id="thetexttitle">サヨナラ - C&K</div>
''';

/// 一行正文，`sentenceSpans` 是这一句里的词元 span（真实页面的形状）。
String _pageHtml(String sentenceSpans) => '''
<div id="thetext">
<p>
  <span class="textsentence" id="sent_4">
$sentenceSpans
  </span>
  <span class="textitem">&ZeroWidthSpace;</span>
</p>
</div>
''';

void main() {
  test('overlapped 词元取页面实显文字，不重复共用的字', () {
    // 摘自书 1143 第 1 页第 4 行的真实 HTML：`のか` 占 `の\u200bか`，
    // 与之重叠的 `かな` 只剩尾部 `な`，但它的 data-text 仍是 `か\u200bな`。
    final page = _pageHtml('''
    <span id="ID-4-27" class="textitem click word word6849 sentencestart"
          data-lang-id="13" data-paragraph-id="3" data-sentence-id="3"
          data-text="愛し" data-status-class="status1" data-order="27"
          data-wid="6849">愛し</span>
    <span id="ID-4-28" class="textitem click word word476"
          data-lang-id="13" data-paragraph-id="3" data-sentence-id="3"
          data-text="た" data-status-class="status1" data-order="28"
          data-wid="476">た</span>
    <span id="ID-4-29" class="textitem click word word6731"
          data-lang-id="13" data-paragraph-id="3" data-sentence-id="3"
          data-text="の&#8203;か" data-status-class="status1" data-order="29"
          data-wid="6731">のか</span>
    <span id="ID-4-30" class="textitem click word word1567 overlapped"
          data-lang-id="13" data-paragraph-id="3" data-sentence-id="3"
          data-text="か&#8203;な" data-status-class="status1" data-order="30"
          data-wid="1567">な</span>
    <span id="ID-4-31" class="textitem" data-text="?">?</span>
''');

    final pageData = HtmlParser().parsePage(
      page,
      _metadataHtml,
      bookId: 1143,
    );
    final items = pageData.paragraphs.single.textItems;

    expect(
      items.map((item) => item.displayText).join(),
      '愛したのかな?',
      reason: '共用的「か」只能出现一次（页面显示的就是这个）',
    );
    expect(
      items.firstWhere((item) => item.wordId == 6731).text,
      'の\u200bか',
      reason: '普通多词词元仍用 data-text（零宽空格是词元内的分隔标记）',
    );
    expect(
      items.firstWhere((item) => item.wordId == 1567).text,
      'な',
      reason: 'overlapped 词元取实显文字，且不影响词元 id',
    );
  });

  test('普通词元照旧取 data-text（零宽空格保留给朗读层）', () {
    final page = _pageHtml('''
    <span id="ID-1-0" class="textitem click word word38 sentencestart"
          data-lang-id="13" data-paragraph-id="0" data-sentence-id="0"
          data-text="小さくなっ&#8203;て" data-status-class="status1"
          data-order="0" data-wid="38">小さくなって</span>
''');

    final pageData = HtmlParser().parsePage(
      page,
      _metadataHtml,
      bookId: 1143,
    );
    final item = pageData.paragraphs.single.textItems.single;

    expect(item.text, '小さくなっ\u200bて');
    expect(item.displayText, '小さくなって');
  });
}
