import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/network/dictionary_service.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/core/network/local_dict.dart';

/// 本地词典（服务器词典池里的 .db）在 App 侧的契约。
///
/// 背景：Lute 的语言设置里，本地词典那一行的 dicturi 是**池文件名**而不是
/// URL（模板见 lute/templates/language/_form.html）。Web 端会把它换成
/// `/read/localdict/<langid>/<file>/<term>`；App 之前直接把它交给 WebUri，
/// 变成 `http://moji-xxxx.db/`，于是 `net::ERR_NAME_NOT_RESOLVED`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 服务器真实渲染形状：本地词典行同时有隐藏的文本输入（文件名）和池下拉框。
  const localDictHtml = '''
<div class="dict_entry">
  <select class="dict-usefor" name="dictionaries-0-usefor">
    <option value="terms" selected>Terms</option>
    <option value="sentences">Sentences</option>
  </select>
  <select class="dict-type" name="dictionaries-0-dicttype">
    <option value="online" selected>Online</option>
    <option value="localdict">Local</option>
  </select>
  <input class="dict-uri" hidden disabled name="dictionaries-0-dicturi"
         value="moji-b4c7cae9.db" />
  <select class="dict-uri" id="dictionaries-0-dicturi-local"
          name="dictionaries-0-dicturi">
    <option value="other.db">Other dictionary</option>
    <option value="moji-b4c7cae9.db" selected>もじ辞書 · 120,000 entries · 12 MB</option>
  </select>
  <input type="checkbox" name="dictionaries-0-is_active" checked />
</div>
<div class="dict_entry">
  <select class="dict-usefor" name="dictionaries-1-usefor">
    <option value="terms" selected>Terms</option>
  </select>
  <select class="dict-type" name="dictionaries-1-dicttype">
    <option value="online" selected>Online</option>
    <option value="localdict">Local</option>
  </select>
  <input class="dict-uri" name="dictionaries-1-dicturi"
         value="https://jisho.org/search/[LUTE]" />
  <input type="checkbox" name="dictionaries-1-is_active" checked />
</div>
''';

  group('parseLanguageDictionaries', () {
    test('本地词典：识别 isLocal，名字取池下拉框标题而不是文件名', () {
      final dicts = HtmlParser().parseLanguageDictionaries(localDictHtml);
      expect(dicts, hasLength(2));

      final local = dicts.first;
      expect(local.isLocalDictionary, isTrue);
      expect(local.urlTemplate, 'moji-b4c7cae9.db');
      expect(local.name, 'もじ辞書', reason: '应取 label 里 · 前的标题');

      final online = dicts.last;
      expect(online.isLocalDictionary, isFalse);
      expect(online.urlTemplate, 'https://jisho.org/search/[LUTE]');
    });

    test('只有文件名、没有类型下拉也能识别', () {
      const html = '''
<div class="dict_entry">
  <input name="dicturi" value="moji-abc.db" />
  <select name="usefor"><option value="terms" selected>Terms</option></select>
  <input type="checkbox" name="is_active" checked />
</div>
''';
      final dicts = HtmlParser().parseLanguageDictionaries(html);
      expect(dicts.single.isLocalDictionary, isTrue);
      expect(dicts.single.name, 'moji-abc', reason: '没有标题就用文件名兜底');
    });
  });

  group('buildDictionaryUrl', () {
    final service = DictionaryService(
      fetchLanguageSettingsHtml: (_) async => localDictHtml,
    );

    test('本地词典走服务器的 /read/localdict 查询路由', () {
      final url = service.buildDictionaryUrl(
        term: '携帯',
        dictionary: const DictionarySource(
          name: 'もじ辞書',
          urlTemplate: 'moji-b4c7cae9.db',
          isLocal: true,
        ),
        languageId: 3,
        serverUrl: 'https://example.org',
      );
      expect(
        url,
        'https://example.org/read/localdict/3/moji-b4c7cae9.db/'
        '%E6%90%BA%E5%B8%AF',
      );
    });

    test('serverUrl 末尾带斜杠不会拼出双斜杠', () {
      final url = service.buildDictionaryUrl(
        term: 'x',
        dictionary: const DictionarySource(name: 'd', urlTemplate: 'a.db'),
        languageId: 1,
        serverUrl: 'https://example.org/',
      );
      expect(url, 'https://example.org/read/localdict/1/a.db/x');
    });

    test('在线词典仍然是模板替换', () {
      final url = service.buildDictionaryUrl(
        term: '携帯',
        dictionary: const DictionarySource(
          name: 'Jisho',
          urlTemplate: 'https://jisho.org/search/[LUTE]',
        ),
        languageId: 3,
        serverUrl: 'https://example.org',
      );
      expect(url, 'https://jisho.org/search/%E6%90%BA%E5%B8%AF');
    });
  });

  group('缓存兼容', () {
    test('旧缓存里名字被兜底成 Dictionary 时按文件名重建', () {
      final source = DictionarySource.fromJson({
        'name': 'Dictionary',
        'urlTemplate': 'moji-abc.db',
      });
      expect(source.isLocalDictionary, isTrue, reason: '老缓存没有 isLocal 字段');
      expect(source.name, 'moji-abc');
    });

    test('新缓存的 isLocal 会被序列化并读回', () async {
      SharedPreferences.setMockInitialValues({});
      final service = DictionaryService(
        fetchLanguageSettingsHtml: (_) async => localDictHtml,
      );
      final dicts = await service.getDictionariesForLanguage(9);
      expect(dicts.first.isLocal, isTrue);

      // 换一个实例（强制回读 SharedPreferences 缓存）验证往返。
      final reopened = DictionaryService(
        fetchLanguageSettingsHtml: (_) async => '<html></html>',
      );
      final cached = await reopened.getDictionariesForLanguage(9);
      expect(cached.first.isLocalDictionary, isTrue);
      expect(cached.first.name, 'もじ辞書');
    });
  });

  group('local_dict helpers', () {
    test('只有裸文件名算本地词典', () {
      expect(looksLikeLocalDictFile('moji.db'), isTrue);
      expect(looksLikeLocalDictFile('  MOJI.DB '), isTrue);
      expect(looksLikeLocalDictFile('https://x.org/a.db'), isFalse);
      expect(looksLikeLocalDictFile('https://x.org/search?q=a'), isFalse);
      expect(looksLikeLocalDictFile(''), isFalse);
    });
  });
}
