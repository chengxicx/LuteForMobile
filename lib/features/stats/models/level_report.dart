/// Vocabulary progress against a graded word list (JLPT, CEFR, TOPIK, DELE,
/// HSK, ...).
///
/// Every one of those endpoints answers with the same shape:
/// `{levels: [{level, total, seen, mastered}], total, total_seen,
/// total_mastered}`, so one model and one card cover all of them.
class LevelReport {
  final List<LevelProgress> levels;
  final int total;
  final int totalSeen;
  final int totalMastered;

  const LevelReport({
    this.levels = const [],
    this.total = 0,
    this.totalSeen = 0,
    this.totalMastered = 0,
  });

  factory LevelReport.fromJson(Map<String, dynamic> json) {
    return LevelReport(
      levels: (json['levels'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => LevelProgress.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      total: _asInt(json['total']),
      totalSeen: _asInt(json['total_seen']),
      totalMastered: _asInt(json['total_mastered']),
    );
  }

  bool get isEmpty => levels.isEmpty || total == 0;

  /// Share of the whole list that has been fully mastered, 0-100.
  double get masteredPercent => total == 0 ? 0 : totalMastered * 100 / total;

  /// Share of the whole list that has been seen at all, 0-100.
  double get seenPercent => total == 0 ? 0 : totalSeen * 100 / total;

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}

/// One level of a report (N5, A2, TOPIK I, HSK 3, ...).
class LevelProgress {
  final String level;
  final int total;
  final int seen;
  final int mastered;

  const LevelProgress({
    required this.level,
    required this.total,
    required this.seen,
    required this.mastered,
  });

  factory LevelProgress.fromJson(Map<String, dynamic> json) {
    return LevelProgress(
      level: '${json['level'] ?? ''}',
      total: LevelReport._asInt(json['total']),
      seen: LevelReport._asInt(json['seen']),
      mastered: LevelReport._asInt(json['mastered']),
    );
  }

  /// Seen but not mastered -- the web panel's "unmastered" tab.
  int get unmastered => (seen - mastered).clamp(0, seen);

  /// In the list but never seen.
  int get notSeen => (total - seen).clamp(0, total);

  double get masteredRatio => total == 0 ? 0 : mastered / total;
  double get seenRatio => total == 0 ? 0 : seen / total;
}
