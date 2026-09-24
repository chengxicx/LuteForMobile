import 'package:flutter/foundation.dart';
import 'stats_data.dart';

@immutable
class LanguageReadingStats {
  final String language;
  final List<DailyReadingStats> dailyStats;

  const LanguageReadingStats({
    required this.language,
    required this.dailyStats,
  });

  int get totalWords => dailyStats.fold(0, (sum, stat) => sum + stat.wordcount);

  int get totalDays => dailyStats.length;

  DateTime? get firstDate => dailyStats.isEmpty ? null : dailyStats.first.date;

  DateTime? get lastDate => dailyStats.isEmpty ? null : dailyStats.last.date;

  factory LanguageReadingStats.fromJson(Map<String, dynamic> json) {
    // 容错：字段缺失或为 null 时退化为空值，而不是抛异常让整页统计打不开。
    final rawList = json['dailyStats'];
    final dailyStats = rawList is List
        ? rawList
              .whereType<Map<String, dynamic>>()
              .map(DailyReadingStats.fromJson)
              .toList()
        : <DailyReadingStats>[];

    return LanguageReadingStats(
      language: json['language'] as String? ?? '',
      dailyStats: dailyStats,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'language': language,
      'dailyStats': dailyStats.map((e) => e.toJson()).toList(),
    };
  }

  LanguageReadingStats copyWith({
    String? language,
    List<DailyReadingStats>? dailyStats,
  }) {
    return LanguageReadingStats(
      language: language ?? this.language,
      dailyStats: dailyStats ?? this.dailyStats,
    );
  }
}
