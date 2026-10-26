// 词保存的 payload 必须带上服务器表单校验要的字段。
//
// 真机现象（离线标记 → 联网自动同步后标记消失）的根因就在这里：
// `/read/edit_term/<id>` 提交的是整条词，`lute.term.forms.TermForm` 的
// `validate_text` 把「original_text 为空」当作**新词**，于是拿它去查重，
// 查到这条词自己 → `Term already exists` → `validate_on_submit()` 失败。
// 服务器把失败渲染成表单页（HTTP 200），客户端看不出区别，outbox 记成
// 「已发送」、删掉 intent，乐观颜色随之撤销。
//
// 用真服务器的 TermForm 复现过三种 payload：
//   {text,translation,status,romanization,current_image}        -> invalid
//   + language_id                                               -> invalid
//   + language_id + original_text（=原词形）                     -> valid
//
// 运行：flutter test test/term_form_payload_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/features/reader/models/term_form.dart';

TermForm _form({int? termId, String? originalText, String text = '出会う'}) {
  return TermForm(
    term: text,
    originalText: originalText,
    termId: termId,
    languageId: 13,
    status: '1',
    syncStatus: true,
  );
}

void main() {
  test('编辑已有词：payload 带 language_id 和 original_text', () {
    final data = _form(termId: 42).toFormData();

    expect(data['text'], '出会う');
    expect(data['language_id'], '13');
    expect(data['status'], '1');
    // 没有 originalText 时回退到当前词形，否则服务器会当成新词查重。
    expect(data['original_text'], '出会う');
  });

  test('只改大小写时 original_text 保持服务器上的原词形', () {
    final data = _form(
      termId: 42,
      originalText: '出会う',
    ).copyWith(term: '出会ウ').toFormData();

    expect(data['text'], '出会ウ');
    expect(data['original_text'], '出会う');
  });

  test('新词（还没有 termId）original_text 留空，走服务器的建词分支', () {
    final data = _form(termId: null).toFormData();

    expect(data['original_text'], '');
  });

  test('parseTermForm 从 hidden original_text 读原词形', () {
    const html = '''
    <form id="term-form">
      <input type="hidden" name="original_text" value="出会う">
      <input type="text" name="text" value="出会う">
      <select name="language_id"><option value="13" selected>Japanese</option></select>
      <input type="radio" name="status" value="1" checked>
      <input type="radio" name="status" value="2">
    </form>
    ''';

    final parsed = HtmlParser().parseTermForm(html, termId: 42);

    expect(parsed.originalText, '出会う');
    expect(parsed.toFormData()['original_text'], '出会う');
    expect(parsed.toFormData()['language_id'], '13');
  });
}
