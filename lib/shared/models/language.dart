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
