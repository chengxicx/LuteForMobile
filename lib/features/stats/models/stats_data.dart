import 'package:flutter/foundation.dart';

@immutable
class DailyReadingStats {
  final DateTime date;
  final int wordcount;
  final int runningTotal;

  const DailyReadingStats({
    required this.date,
    required this.wordcount,
    required this.runningTotal,
  });

  factory DailyReadingStats.fromJson(Map<String, dynamic> json) {
    // 容错：readdate 缺失或格式非法时退化为 epoch，
    // 而不是抛异常让整页阅读统计打不开。
    final rawDate = json['readdate'];
    DateTime parsedDate;
    try {
      parsedDate = rawDate is String && rawDate.isNotEmpty
          ? DateTime.parse(rawDate)
          : DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      parsedDate = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return DailyReadingStats(
      date: parsedDate,
      wordcount: json['wordcount'] as int? ?? 0,
      runningTotal: json['runningTotal'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'readdate': date.toIso8601String().split('T').first,
      'wordcount': wordcount,
      'runningTotal': runningTotal,
    };
  }

  DailyReadingStats copyWith({
    DateTime? date,
    int? wordcount,
    int? runningTotal,
  }) {
    return DailyReadingStats(
      date: date ?? this.date,
      wordcount: wordcount ?? this.wordcount,
      runningTotal: runningTotal ?? this.runningTotal,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DailyReadingStats &&
        other.date == date &&
        other.wordcount == wordcount &&
        other.runningTotal == runningTotal;
  }

  @override
  int get hashCode => Object.hash(date, wordcount, runningTotal);
}
