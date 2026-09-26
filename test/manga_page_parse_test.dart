// Manga 页数据契约测试（词卡发音的根）。
//
// manga 页的 HTML 没有 .textsentence 包裹，parsePage 出来的 paragraphs
// 恒为空 —— reader 的 _findLangId 曾因此拿到 null，TTS 语言退回设置里的
// 兜底 'en'，日文词被丢给英文语音（edge-tts 422，词卡彻底无声，nginx
// 日志里一片 /tts/en/言う）。
//
//   1. manga 页 paragraphs 为空、mangaPage.blocks 有数据；
//   2. 文字项的 data-lang-id 落在 block TextItem.langId 上（_findLangId
//      的 manga 补扫依赖它）。
//
// 运行：flutter test test/manga_page_parse_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';

const _mangaPageHtml = '''
<div class="manga-page" data-page-width="1080" data-page-height="1530">
  <img class="manga-page-img" src="/static/manga/x/001.jpg" />
  <div class="manga-text-block" style="left: 10.000%; top: 5.000%; width: 30.000%; height: 60.000%;">
    <div class="manga-text-line" style="font-size: 2.963cqw;">
      <span id="ti0" class="textitem status0" data-lang-id="7"
            data-paragraph-id="0" data-sentence-id="0" data-text="世界"
            data-status-class="status0" data-order="0" data-wid="42">世界</span>
      <span id="ti1" class="textitem status1" data-lang-id="7"
            data-paragraph-id="0" data-sentence-id="0" data-text="だ"
            data-status-class="status1" data-order="1" data-wid="43">だ</span>
    </div>
  </div>
</div>
''';

const _metadataHtml = '''
<input id="page_num" value="1" />
<input id="page_count" value="10" />
<div id="thetexttitle">Manga test</div>
''';

void main() {
  test('manga 页 paragraphs 为空，langId 从 manga blocks 的文字项上取', () {
    final pageData = HtmlParser().parsePage(
      _mangaPageHtml,
      _metadataHtml,
      bookId: 1,
    );

    final mangaPage = pageData.mangaPage;
    expect(mangaPage, isNotNull);

    // 没有 .textsentence：段落列表是空的 —— 这是 _findLangId 必须补扫
    // manga blocks 的原因。
    expect(pageData.paragraphs, isEmpty);

    // OCR 文字项带着 data-lang-id。
    final items = mangaPage!.blocks.single.lineItems.single;
    expect(items.first.langId, 7);
    expect(items.first.text, '世界');
    expect(items.last.langId, 7);
    expect(items.last.text, 'だ');
  });
}
