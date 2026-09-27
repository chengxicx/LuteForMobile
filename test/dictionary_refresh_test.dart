import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/core/network/dictionary_service.dart';

/// 词典缓存后台静默刷新（方案 A）的契约测试。
///
/// 背景：词典列表原来只在本地缓存为空时从服务器拉一次，之后永不更新，
/// 服务器新增词典 App 永远看不到。refreshDictionariesForLanguage 现在
/// 用于打开词典弹窗时的后台刷新，必须保证：成功才覆盖缓存，
/// 网络失败/解析为空绝不清空用户已有配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const htmlWithSentenceDict = '''
<div class="dict_entry">
  <input name="dicturi1" value="https://example.org/translate?q={sentence}" />
  <select name="usefor1">
    <option value="terms">Terms</option>
    <option value="sentences" selected>Sentences</option>
  </select>
  <input type="checkbox" name="is_active1" checked />
</div>
''';

  Future<DictionaryService> makeService(
    Future<String?> Function(int) fetch,
  ) async {
    SharedPreferences.setMockInitialValues({});
    return DictionaryService(fetchLanguageSettingsHtml: fetch);
  }

  group('refreshDictionariesForLanguage', () {
    test('拉到新词典：返回 true 且缓存被覆盖', () async {
      final service = await makeService((_) async => htmlWithSentenceDict);

      final ok = await service.refreshDictionariesForLanguage(42);
      expect(ok, isTrue);

      final dicts = await service.getSentenceDictionariesForLanguage(42);
      expect(dicts, hasLength(1));
      expect(dicts.first.urlTemplate, contains('{sentence}'));
    });

    test('拉取抛异常：返回 false 且不清空现有缓存', () async {
      final service = await makeService((_) async => htmlWithSentenceDict);
      await service.refreshDictionariesForLanguage(42);
      final before = await service.getSentenceDictionariesForLanguage(42);
      expect(before, isNotEmpty);

      // 换成一个必然抛异常的 fetch（模拟网络抖动）
      final failing = DictionaryService(
        fetchLanguageSettingsHtml: (_) async => throw Exception('network'),
      );
      final ok = await failing.refreshDictionariesForLanguage(42);
      expect(ok, isFalse);

      final after = await service.getSentenceDictionariesForLanguage(42);
      expect(after, hasLength(before.length), reason: '失败不能把缓存冲掉');
    });

    test('解析结果为空：返回 false 且保留缓存', () async {
      final service = await makeService((_) async => htmlWithSentenceDict);
      await service.refreshDictionariesForLanguage(42);
      final before = await service.getSentenceDictionariesForLanguage(42);
      expect(before, isNotEmpty);

      final empty = DictionaryService(
        fetchLanguageSettingsHtml: (_) async => '<html><body></body></html>',
      );
      final ok = await empty.refreshDictionariesForLanguage(42);
      expect(ok, isFalse);

      final after = await service.getSentenceDictionariesForLanguage(42);
      expect(after, hasLength(before.length));
    });
  });

  group('sameDictionaries', () {
    test('同构列表视为无变化', () {
      final a = [
        const DictionarySource(name: 'A', urlTemplate: 'u1'),
        const DictionarySource(name: 'B', urlTemplate: 'u2', isAI: true),
      ];
      final b = [
        const DictionarySource(name: 'A', urlTemplate: 'u1'),
        const DictionarySource(name: 'B', urlTemplate: 'u2', isAI: true),
      ];
      expect(sameDictionaries(a, b), isTrue);
    });

    test('模板或数量不同视为有变化', () {
      final a = [const DictionarySource(name: 'A', urlTemplate: 'u1')];
      final b = [const DictionarySource(name: 'A', urlTemplate: 'u2')];
      final c = [
        const DictionarySource(name: 'A', urlTemplate: 'u1'),
        const DictionarySource(name: 'B', urlTemplate: 'u2'),
      ];
      expect(sameDictionaries(a, b), isFalse);
      expect(sameDictionaries(a, c), isFalse);
    });
  });
}
