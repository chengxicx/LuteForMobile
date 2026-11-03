/// Where a language list came from.
///
/// `language/index` is admin-only on a multiuser server, so a sub-user falls
/// back to the add-book form and then to languages already present on the
/// shelf.  The settings page needs this to explain a fallback instead of
/// pretending the list is still loading.
enum LanguageListSource {
  /// Parsed from `/language/index` (admin path).
  server,

  /// Parsed from the `select#language_id` on `/book/new` (sub-user path).
  bookForm,

  /// Derived from the books already on the shelf (last-resort offline path).
  bookShelf,

  /// Nothing to show.
  none,
}

/// Terminal outcome of a language-list load.
///
/// [failed] means at least one stage could not be reached/parsed; combined
/// with an empty [languages] it lets the UI say "could not load" rather than
/// "loading" forever.
class LanguageListResult {
  const LanguageListResult({
    required this.languages,
    required this.source,
    this.failed = false,
  });

  final List<Language> languages;
  final LanguageListSource source;
  final bool failed;

  bool get isEmpty => languages.isEmpty;

  bool get usedFallback =>
      source == LanguageListSource.bookForm ||
      source == LanguageListSource.bookShelf;
}

class Language {
  final int id;
  final String name;

  /// 是否未冻结（服务端 LgIsActive）。
  ///
  /// 冻结（frozen）的语言在 web 端不出现在书单的语言过滤下拉里
  /// （见 lute/utils/formutils.py 的 `language_choices`，默认
  /// `include_inactive=False`），移动端对齐这一行为。
  final bool isActive;

  Language({required this.id, required this.name, this.isActive = true});

  factory Language.fromJson(Map<String, dynamic> json) {
    // 容错转换，避免服务端字段为 null 时整页崩溃。
    final rawId = json['id'];
    return Language(
      id: rawId is int
          ? rawId
          : rawId is num
          ? rawId.toInt()
          : int.tryParse('$rawId') ?? 0,
      name: json['name'] as String? ?? '',
      isActive: json['isActive'] as bool? ?? json['is_active'] as bool? ?? true,
    );
  }
}
