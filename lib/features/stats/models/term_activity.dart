/// Payload of `GET /stats/term_data`: the four panels the web stats page
/// builds out of it (summary, new terms, mastered terms, activity heatmap).
class TermActivity {
  final TermSummary summary;
  final List<TermTrendPoint> newTerms;
  final List<TermTrendPoint> masteredTerms;
  final List<TermTrendPoint> heatmap;

  const TermActivity({
    required this.summary,
    this.newTerms = const [],
    this.masteredTerms = const [],
    this.heatmap = const [],
  });

  static const TermActivity empty = TermActivity(summary: TermSummary.empty);

  factory TermActivity.fromJson(Map<String, dynamic> json) {
    return TermActivity(
      summary: TermSummary.fromJson(
        json['summary'] is Map
            ? Map<String, dynamic>.from(json['summary'] as Map)
            : const {},
      ),
      newTerms: TermTrendPoint.listFromJson(json['new_terms']),
      masteredTerms: TermTrendPoint.listFromJson(json['mastered_terms']),
      heatmap: TermTrendPoint.listFromJson(json['heatmap']),
    );
  }
}

/// Term counts by status: all time, and for the selected period.
class TermSummary {
  final int totalTerms;
  final Map<int, int> recentByStatus;
  final String recentLabel;
  final Map<int, int> cumulativeByStatus;

  const TermSummary({
    this.totalTerms = 0,
    this.recentByStatus = const {},
    this.recentLabel = 'Recent',
    this.cumulativeByStatus = const {},
  });

  static const TermSummary empty = TermSummary();

  factory TermSummary.fromJson(Map<String, dynamic> json) {
    return TermSummary(
      totalTerms: _asInt(json['total_terms']),
      recentByStatus: _asStatusMap(json['recent_by_status']),
      recentLabel: _asLabel(json['recent_label']),
      cumulativeByStatus: _asStatusMap(json['cumulative_by_status']),
    );
  }

  int get recentTotal => recentByStatus.values.fold(0, (a, b) => a + b);

  /// Counts bucketed the way the web panel groups them: statuses 1-5 are
  /// "vague" (still being learned), 99 is "mastered", 98 is "ignored".
  Map<TermStatusGroup, int> group(Map<int, int> byStatus) {
    final out = <TermStatusGroup, int>{};
    for (final entry in byStatus.entries) {
      final group = TermStatusGroup.forStatus(entry.key);
      out[group] = (out[group] ?? 0) + entry.value;
    }
    return out;
  }

  static Map<int, int> _asStatusMap(dynamic value) {
    if (value is! Map) return const {};
    final out = <int, int>{};
    for (final entry in value.entries) {
      final status = int.tryParse('${entry.key}');
      if (status == null) continue;
      out[status] = _asInt(entry.value);
    }
    return out;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static String _asLabel(dynamic value) {
    if (value is! String) return 'Recent';
    final text = value.trim();
    return text.isEmpty ? 'Recent' : text;
  }
}

enum TermStatusGroup {
  unknown('Unknown'),
  vague('Vague'),
  mastered('Mastered'),
  ignored('Ignored'),
  other('Other');

  final String label;
  const TermStatusGroup(this.label);

  static TermStatusGroup forStatus(int status) {
    if (status == 0) return TermStatusGroup.unknown;
    if (status >= 1 && status <= 5) return TermStatusGroup.vague;
    if (status == 99) return TermStatusGroup.mastered;
    if (status == 98) return TermStatusGroup.ignored;
    return TermStatusGroup.other;
  }
}

/// One `{date, count}` bucket.  Dates are `yyyy-MM-dd`; the monthly period
/// buckets them to the first of the month, so keep them as parsed dates
/// rather than assuming daily granularity.
class TermTrendPoint {
  final DateTime date;
  final int count;

  const TermTrendPoint({required this.date, required this.count});

  static List<TermTrendPoint> listFromJson(dynamic value) {
    if (value is! List) return const [];
    final points = <TermTrendPoint>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final date = DateTime.tryParse('${raw['date']}');
      if (date == null) continue;
      final count = raw['count'];
      points.add(
        TermTrendPoint(
          date: date,
          count: count is num ? count.toInt() : int.tryParse('$count') ?? 0,
        ),
      );
    }
    points.sort((a, b) => a.date.compareTo(b.date));
    return points;
  }
}
