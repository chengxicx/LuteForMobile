import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/language.dart';
import '../../features/books/providers/books_provider.dart';
import './network_providers.dart';

final languageListProvider = FutureProvider<List<Language>>((ref) async {
  final contentService = ref.read(contentServiceProvider);
  return await contentService.getLanguagesWithIds();
});

final languageNamesProvider = FutureProvider<List<String>>((ref) async {
  final languages = await ref.watch(languageListProvider.future);
  return languages.map((lang) => lang.name).toList();
});

/// 仅含未冻结语言的名称。
///
/// 对齐 web 端行为（language_choices 默认 include_inactive=False）：
/// 冻结（frozen）的语言不出现在书籍过滤的语言列表里。
///
/// 服务端 `/language/index` 拉不到时（离线）退回**书架缓存里的书自带
/// 的语言名**：书籍过滤是纯本地功能，不该因为一次网络请求失败就整行
/// 消失。书架 BooksState 本身是磁盘缓存的，离线时 activeBooks /
/// archivedBooks 仍然带着每本书的 `LgName`。
final activeLanguageNamesProvider = FutureProvider<List<String>>((ref) async {
  try {
    final languages = await ref
        .watch(languageListProvider.future)
        .timeout(const Duration(seconds: 4));
    final names = languages
        .where((lang) => lang.isActive)
        .map((lang) => lang.name)
        .toList();
    if (names.isNotEmpty) return names;
  } catch (_) {
    // 离线：/language/index 不可达，走下面的书架兜底。
  }

  final books = ref.watch(booksProvider);
  final seen = <String>{};
  for (final book in [...books.activeBooks, ...books.archivedBooks]) {
    final name = book.language.trim();
    if (name.isEmpty) continue;
    seen.add(name);
  }
  return seen.toList()..sort();
});
