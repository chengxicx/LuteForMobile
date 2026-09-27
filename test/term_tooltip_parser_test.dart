import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';

/// 用生产 Song 服务器 /read/termpopup 真实渲染出来的 HTML（2026-09-27 抓取）
/// 做用例，防止解析逻辑再漂移。
///
/// 服务端模板段落顺序：术语、（可选 flash）、（可选读音 <p><i>かな</i></p>）、
/// 释义、（可选 parents / components 分区）。
void main() {
  final parser = HtmlParser();

  group('parseTermTooltip 释义段定位', () {
    test('日语词带假名读音：释义不被读音段顶掉', () {
      // 生产 render（term 13382 動きます）的节选
      final html = '''
<p>
  <b style="font-size:120%">
    動きます (動く)
  </b>
</p>
<p><i>うごきます</i></p>
<p>[自动词・五段/一类]<br />变动；移动；动弹。<br />摇动；摆动。</p>
<div style="margin-top: 1.5em;">
  <p>
    <b>動く</b>
    <i>(うごく)</i>
    <br />[自动词・五段/一类]<br />变动，移动，动弹。
  </p>
</div>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.term, contains('動きます'));
      expect(tooltip.translation, isNotNull);
      expect(
        tooltip.translation,
        isNot(equals('うごきます')),
        reason: '读音段（纯 <i> 段）不能被当成释义',
      );
      expect(tooltip.translation, contains('变动；移动；动弹'));
      // 读音要单独捕获，词卡上与释义分行同显。
      expect(tooltip.romanization, 'うごきます');
    });

    test('英语词无读音：romanization 为 null', () {
      final html = '''
<p>
  <b style="font-size:120%">
    pageantry
  </b>
</p>
<p>盛典</p>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.romanization, isNull);
    });

    test('英语词无读音：第一段普通段落即释义', () {
      // 生产 render（term 13583 pageantry）
      final html = '''
<p>
  <b style="font-size:120%">
    pageantry
  </b>
</p>
<p>盛典</p>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.term, contains('pageantry'));
      expect(tooltip.translation, '盛典');
    });

    test('无释义词：translation 为 null', () {
      final html = '''
<p>
  <b style="font-size:120%">
    新词
  </b>
</p>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.translation, isNull);
    });

    test('无释义但有 components：不把 Components 标题当释义', () {
      final html = '''
<p>
  <b style="font-size:120%">
    てます
  </b>
</p>
<div style="margin-top: 1.5em;">
  <p><i>Components</i></p>
  <p>
    <b>て</b>
    <i>(te)</i>
    <br />手
  </p>
</div>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.translation, isNull);
      // components 分区里的条目（<b>て</b>…<br />手）也不能被当成释义
      expect(tooltip.translation, isNot(contains('手')));
    });

    test('flash 提示段跳过', () {
      final html = '''
<p>
  <b style="font-size:120%">
    word
  </b>
</p>
<p class="small-flash-notice">some flash notice</p>
<p>释义</p>
''';
      final tooltip = parser.parseTermTooltip(html);
      expect(tooltip.translation, '释义');
    });
  });
}
