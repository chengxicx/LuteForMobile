import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/language.dart';
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
final activeLanguageNamesProvider = FutureProvider<List<String>>((ref) async {
  final languages = await ref.watch(languageListProvider.future);
  return languages
      .where((lang) => lang.isActive)
      .map((lang) => lang.name)
      .toList();
});
