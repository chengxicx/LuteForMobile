import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/widgets/offline_sentence_ai_html.dart';

// 离线页与联网页共用同一套网页模板：这里锁住 DOM 骨架、结果渲染函数、
// 主题 CSS 注入，以及「动态文本不能截断 <script>」这条安全底线。
void main() {
  const themeCss = 'body { --font-color: #123456 !important; }';

  String build({
    String sentence = 'あ、やっとつながった。',
    Map<String, dynamic>? result,
    String? fallback,
    bool hasContent = true,
  }) =>
      buildOfflineSentenceAiHtml(
        sentence: sentence,
        result: result,
        fallbackText: fallback,
        themeCss: themeCss,
        providerLabel: 'Local cache',
        badgeLabel: hasContent ? 'Cached' : 'Offline',
        hasContent: hasContent,
        emptyMessage: '这句没有离线解释',
      );

  test('keeps the server page skeleton and render functions', () {
    final html = build(
      result: <String, dynamic>{
        'translation': '啊，终于连上了。',
        'segments': <Map<String, dynamic>>[
          <String, dynamic>{
            'part': 'あ、',
            'meaning': '啊',
            'role': '感叹词',
          },
        ],
      },
    );

    expect(html, contains('<div class="ai-card">'));
    expect(html, contains('id="ai-source-text"'));
    expect(html, contains('id="ai-result"'));
    expect(html, contains('id="ai-sections"'));
    expect(html, contains('id="ai-retry"'));
    expect(html, contains("table.className = 'ai-table'"));
    expect(html, contains('function renderSegments'));
    expect(html, contains('function renderGrammar'));
    expect(html, contains('function renderExamples'));
    // Same theme CSS the online page injects, embedded rather than fetched.
    expect(html, contains(themeCss));
    // No remote assets: the page must render with the radio off.
    expect(html, isNot(contains('<link')));
    expect(html, isNot(contains('http://')));
    expect(html, isNot(contains('https://')));
  });

  test('reveals the status badge that the server page shows', () {
    final html = build(
      result: <String, dynamic>{'translation': '啊，终于连上了。'},
    );
    // The span is `hidden` in the markup, so the script MUST clear the
    // attribute when a label exists. A one-way `if (!label) hidden = true`
    // regressed here: Cached / Offline stayed invisible forever.
    expect(html, contains('id="ai-badge" class="ai-badge" hidden'));
    expect(html, contains('badge.hidden = !DATA.badgeLabel;'));
    expect(html, isNot(contains('if (!DATA.badgeLabel) badge.hidden = true;')));
  });

  test('structured result and labels are passed as JSON data', () {
    final html = build(
      result: <String, dynamic>{
        'translation': '啊，终于连上了。',
        'grammar': <Map<String, dynamic>>[
          <String, dynamic>{'point': 'やっと', 'explanation': '终于'},
        ],
        'context': '电话接通后',
        'examples': <Map<String, dynamic>>[
          <String, dynamic>{'source': 'あ、やっとつながった。'},
        ],
      },
    );
    expect(html, contains('啊，终于连上了。'));
    expect(html, contains('Word-by-word'));
    expect(html, contains('Grammar points'));
    expect(html, contains('"badgeLabel":"Cached"'));
    expect(html, contains('"providerLabel":"Local cache"'));
  });

  test('escapes script-breaking text instead of injecting markup', () {
    const tricky = '</script><script>alert(1)</script>&\u2028';
    final html = build(sentence: tricky, hasContent: false);

    expect(html, contains(r'\u003C/script\u003E'));
    expect(html, isNot(contains('</script><script>alert(1)')));
    expect(html, contains(r'\u0026'));
    expect(html, contains(r'\u2028'));
    // Only the two real script tags remain (data + rendering code).
    expect('<script>'.allMatches(html).length, 1);
    expect(html, contains('"badgeLabel":"Offline"'));
    expect(html, contains('这句没有离线解释'));
  });

  test('falls back to a one-line translation when there is no structure', () {
    final html = build(fallback: '（张：）啊，终于打通了。');
    expect(html, contains('"fallbackText":"（张：）啊，终于打通了。"'));
    expect(html, contains('"result":null'));
  });
}
