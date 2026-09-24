class Language {
  final int id;
  final String name;

  Language({required this.id, required this.name});

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
    );
  }
}
