import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/shared/models/language.dart';

/// `/language/index` 的冻结判定：必须与界面语言无关。
///
/// 服务端模板（lute/templates/language/index.html）对一个语言做三件事：
///   - 行 `style="opacity: 0.5;"`（仅冻结时）
///   - 状态列 `<span style="color: #37b24d">● Active</span>` /
///     `<span style="color: #868e96">● Frozen</span>`
///   - 动作按钮 `background:#fab005`（Freeze）/ `background:#37b24d`（Activate）
/// 文案走 `t('Frozen')`：ui_language=zh 时渲染成 `● 已冻结`。
/// 旧实现只匹配英文 `Frozen`，中文界面下每个语言都被当成 active。
String languageIndexPage({
  required String frozenLabel,
  required String activeLabel,
  required String freezeLabel,
  required String activateLabel,
}) {
  return '''
<html><body>
<table id="languagetable">
  <thead><tr><th>Language</th><th>Status</th><th>Actions</th></tr></thead>
  <tbody>
    <tr style="">
      <td><a href="/language/edit/13">Japanese</a></td>
      <td><span style="color: #37b24d; font-size: 12px;">● $activeLabel</span></td>
      <td>
        <form method="POST" action="/language/toggle_active/13" style="display:inline;">
          <button type="submit" title="$freezeLabel language"
                  style="padding:2px 8px;background:#fab005;color:#fff;border:none;
                         border-radius:4px;cursor:pointer;font-size:12px;">$freezeLabel</button>
        </form>
      </td>
    </tr>
    <tr style="opacity: 0.5;">
      <td><a href="/language/edit/2">Classical Chinese</a></td>
      <td><span style="color: #868e96; font-size: 12px;">● $frozenLabel</span></td>
      <td>
        <form method="POST" action="/language/toggle_active/2" style="display:inline;">
          <button type="submit" title="$activateLabel language"
                  style="padding:2px 8px;background:#37b24d;color:#fff;border:none;
                         border-radius:4px;cursor:pointer;font-size:12px;">$activateLabel</button>
        </form>
      </td>
    </tr>
  </tbody>
</table>
</body></html>
''';
}

void main() {
  final parser = HtmlParser();

  Language byName(List<Language> languages, String name) =>
      languages.firstWhere((lang) => lang.name == name);

  test('中文界面（ui_language=zh）也能识别冻结语言', () {
    final languages = parser.parseLanguagesWithIds(
      languageIndexPage(
        frozenLabel: '已冻结',
        activeLabel: '启用中',
        freezeLabel: '冻结',
        activateLabel: '启用',
      ),
    );

    expect(languages.length, 2);
    expect(byName(languages, 'Japanese').isActive, isTrue);
    expect(byName(languages, 'Classical Chinese').isActive, isFalse);
  });

  test('英文界面同样识别（回归：颜色标记不依赖文案）', () {
    final languages = parser.parseLanguagesWithIds(
      languageIndexPage(
        frozenLabel: 'Frozen',
        activeLabel: 'Active',
        freezeLabel: 'Freeze',
        activateLabel: 'Activate',
      ),
    );

    expect(byName(languages, 'Japanese').isActive, isTrue);
    expect(byName(languages, 'Classical Chinese').isActive, isFalse);
  });

  test('日文界面（凍結済み）同样识别', () {
    final languages = parser.parseLanguagesWithIds(
      languageIndexPage(
        frozenLabel: '凍結済み',
        activeLabel: '有効',
        freezeLabel: '凍結',
        activateLabel: '有効化',
      ),
    );

    expect(byName(languages, 'Classical Chinese').isActive, isFalse);
  });

  test('旧版语言页（无状态列、无标记）默认全部 active', () {
    const legacy = '''
<html><body>
<table><tbody>
  <tr><td><a href="/language/edit/13">Japanese</a></td></tr>
  <tr><td><a href="/language/edit/2">Classical Chinese</a></td></tr>
</tbody></table>
</body></html>
''';

    final languages = parser.parseLanguagesWithIds(legacy);
    expect(languages.every((lang) => lang.isActive), isTrue);
  });

  test('未冻结行里的绿色状态点不被误判为冻结', () {
    // active 行的状态点是 #37b24d、动作按钮是黄色 Freeze；两者都不能触发
    // 「冻结」判定（否则过滤器会把正常语言也藏起来）。
    final languages = parser.parseLanguagesWithIds(
      languageIndexPage(
        frozenLabel: '已冻结',
        activeLabel: '启用中',
        freezeLabel: '冻结',
        activateLabel: '启用',
      ),
    );

    final active = languages.where((lang) => lang.isActive).toList();
    expect(active.map((lang) => lang.name), contains('Japanese'));
    expect(active.map((lang) => lang.name), isNot(contains('Classical Chinese')));
  });
}
