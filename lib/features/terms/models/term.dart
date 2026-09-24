class Term {
  final int id;
  final String text;
  final String? translation;
  final String status;
  final int langId;
  final String language;
  final List<String>? tags;
  final int? parentCount;
  final DateTime? createdDate;

  Term({
    required this.id,
    required this.text,
    this.translation,
    required this.status,
    required this.langId,
    required this.language,
    this.tags,
    this.parentCount,
    this.createdDate,
  });

  String get statusLabel {
    switch (status) {
      case '99':
        return 'Well Known';
      case '0':
        return 'Unknown';
      case '1':
        return 'Learning 1';
      case '2':
        return 'Learning 2';
      case '3':
        return 'Learning 3';
      case '4':
        return 'Learning 4';
      case '5':
        return 'Learning 5';
      case '98':
        return 'Ignored';
      default:
        return 'Unknown';
    }
  }

  factory Term.fromJson(Map<String, dynamic> json) {
    // 容错取整：服务端字段缺失或为 null 时退化，避免词条列表整页崩溃。
    int asInt(dynamic v, [int fallback = 0]) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    return Term(
      id: asInt(json['WoID']),
      text: json['WoText'] as String? ?? '',
      translation: json['WoTranslation'] as String?,
      status: asInt(json['StID']).toString(),
      langId: json['LgID'] as int? ?? 0,
      language: json['LgName'] as String? ?? '',
      tags: (json['Tags'] as String?)
          ?.split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      parentCount: json['ParentCount'] as int?,
      createdDate: DateTime.tryParse(
        (json['CreatedDate'] ?? json['WoCreated']) as String? ?? '',
      ),
    );
  }
}
