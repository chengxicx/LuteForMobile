import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/dict/dict_repository.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/core/prefs/legacy_scope_migration.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('account-scoped preference keys', () {
    test('legacy dict_for_lang_* is claimed once at startup', () async {
      SharedPreferences.setMockInitialValues({
        'dict_for_lang_13': 'jmdict.db',
      });
      await migrateLegacyScopedPrefs(scopeOverride: 'owner');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dict_for_lang_13@owner'), 'jmdict.db');
      expect(
        prefs.getString('dict_for_lang_13'),
        isNull,
        reason: 'the unscoped key is removed so a later account cannot inherit it',
      );

      // Reading through the repository sees the scoped entry without doing
      // any migration of its own.
      final chosen = await DictRepository().selectedDict(13);
      if (SessionManager.cacheScope == 'owner') {
        expect(chosen, 'jmdict.db');
      } else {
        expect(chosen, isNull);
      }
    });

    test('a second account never claims keys already migrated', () async {
      SharedPreferences.setMockInitialValues({
        'dict_for_lang_13': 'jmdict.db',
      });
      await migrateLegacyScopedPrefs(scopeOverride: 'owner');
      await migrateLegacyScopedPrefs(scopeOverride: 'guest');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dict_for_lang_13@owner'), 'jmdict.db');
      expect(prefs.getString('dict_for_lang_13@guest'), isNull);
    });

    test('an existing scoped choice is not overwritten by the legacy key',
        () async {
      SharedPreferences.setMockInitialValues({
        'dict_for_lang_13': 'old.db',
        'dict_for_lang_13@owner': 'new.db',
      });
      await migrateLegacyScopedPrefs(scopeOverride: 'owner');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dict_for_lang_13@owner'), 'new.db');
      expect(prefs.getString('dict_for_lang_13'), isNull);
    });

    test('empty legacy values are dropped, not migrated', () async {
      SharedPreferences.setMockInitialValues({
        'dict_for_lang_13': '',
        'book_lang_name_7': '   ',
        'book_lang_id_7': 0,
      });
      await migrateLegacyScopedPrefs(scopeOverride: 'owner');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dict_for_lang_13@owner'), isNull);
      expect(prefs.getString('book_lang_name_7@owner'), isNull);
      expect(prefs.getInt('book_lang_id_7@owner'), isNull);
      expect(prefs.getString('dict_for_lang_13'), isNull);
      expect(prefs.getString('book_lang_name_7'), isNull);
      expect(prefs.getInt('book_lang_id_7'), isNull);
    });

    test('book language keys are scoped too', () async {
      SharedPreferences.setMockInitialValues({
        'book_lang_id_7': 3,
        'book_lang_name_7': 'Japanese',
      });
      await migrateLegacyScopedPrefs(scopeOverride: 'owner');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('book_lang_id_7@owner'), 3);
      expect(prefs.getString('book_lang_name_7@owner'), 'Japanese');
      expect(prefs.getInt('book_lang_id_7'), isNull);
      expect(prefs.getString('book_lang_name_7'), isNull);
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
