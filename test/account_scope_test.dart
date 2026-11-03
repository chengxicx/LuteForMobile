import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/dict/dict_repository.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/core/network/session_manager.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('account-scoped preference keys', () {
    test('legacy dict_for_lang_* is migrated to the current scope', () async {
      SharedPreferences.setMockInitialValues({
        'dict_for_lang_13': 'jmdict.db',
      });
      final scope = SessionManager.cacheScope;

      final chosen = await DictRepository().selectedDict(13);

      expect(chosen, 'jmdict.db');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dict_for_lang_13@$scope'), 'jmdict.db');
      expect(
        prefs.getString('dict_for_lang_13'),
        isNull,
        reason: 'the unscoped key is removed so a later account cannot inherit it',
      );
    });

    test('selectionMap only reports the current scope', () async {
      final prefs = await SharedPreferences.getInstance();
      final scope = SessionManager.cacheScope;
      await prefs.setString('dict_for_lang_13@$scope', 'jmdict.db');
      await prefs.setString('dict_for_lang_13@other-account', 'other.db');

      final map = await DictRepository().selectionMap();

      expect(map, {13: 'jmdict.db'});
    });
  });

  group('sub-user language source', () {
    test('the /book/new language select is parsed without admin-only pages',
        () {
      // Rendered WTForms select from a role=user GET /book/new (no
      // language/edit links anywhere, which is why /language/index yields 0).
      const html = '''
<html><body>
<form method="post">
  <select class="form-control" id="language_id" name="language_id">
    <option value="0">Please select</option>
    <option value="3">Japanese</option>
    <option value="7">Korean</option>
  </select>
</form>
</body></html>''';

      final languages = HtmlParser().parseLanguagesFromBookNew(html);

      expect(languages.map((l) => l.id), [3, 7]);
      expect(languages.map((l) => l.name), ['Japanese', 'Korean']);
      expect(languages.every((l) => l.isActive), isTrue);
    });

    test('a page without the select yields an empty list', () {
      final languages = HtmlParser().parseLanguagesFromBookNew(
        '<html><body><p>Nothing here</p></body></html>',
      );

      expect(languages, isEmpty);
    });
  });
}
