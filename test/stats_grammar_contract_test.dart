import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/grammar/models/grammar_point.dart';
import 'package:song_mobile/features/grammar/providers/grammar_provider.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/stats/models/level_report.dart';
import 'package:song_mobile/features/stats/models/term_activity.dart';
import 'package:song_mobile/features/stats/providers/level_report_provider.dart';
import 'package:song_mobile/features/stats/providers/stats_provider.dart';
import 'package:song_mobile/features/stats/providers/term_activity_provider.dart';

/// Pins the server contracts the new Stats panels and the Grammar screen are
/// built on, plus the pure derivations that turn those payloads into what the
/// widgets draw.
///
/// The numbers here are the ones the web stats page computes for the same
/// payloads, so a drift in either direction shows up as a failing assertion
/// rather than as a panel that quietly disagrees with the web page.
void main() {
  group('LevelReport.fromJson — the shared shape of /stats/<kind>_data', () {
    test('parses levels and totals', () {
      final report = LevelReport.fromJson({
        'levels': [
          {'level': 'N5', 'total': 100, 'seen': 80, 'mastered': 60},
          {'level': 'N4', 'total': 300, 'seen': 30, 'mastered': 10},
        ],
        'total': 400,
        'total_seen': 110,
        'total_mastered': 70,
      });

      expect(report.levels.length, 2);
      expect(report.levels.first.level, 'N5');
      expect(report.total, 400);
      expect(report.totalSeen, 110);
      expect(report.totalMastered, 70);
      expect(report.masteredPercent, closeTo(17.5, 1e-9));
      expect(report.seenPercent, closeTo(27.5, 1e-9));
      expect(report.isEmpty, isFalse);
    });

    test('accepts numeric strings, which some endpoints send', () {
      final report = LevelReport.fromJson({
        'levels': [
          {'level': 'A1', 'total': '50', 'seen': '10', 'mastered': '5'},
        ],
        'total': '50',
        'total_seen': '10',
        'total_mastered': '5',
      });

      expect(report.total, 50);
      expect(report.totalSeen, 10);
      expect(report.totalMastered, 5);
      expect(report.levels.single.total, 50);
    });

    test('is empty with no levels, or with no terms at all', () {
      expect(LevelReport.fromJson(const {}).isEmpty, isTrue);
      expect(
        LevelReport.fromJson({'levels': const [], 'total': 0}).isEmpty,
        isTrue,
      );
    });

    test('percentages never divide by zero', () {
      final report = LevelReport.fromJson({'levels': const [], 'total': 0});
      expect(report.masteredPercent, 0);
      expect(report.seenPercent, 0);
    });

    test('a non-list levels value fails loudly instead of reporting empty', () {
      // `getLevelReport` guards the top-level shape and the card has an
      // `error:` branch with Retry, so a malformed field must throw its way
      // into that branch.  Silently returning an empty report would render
      // "No word list data for this language yet" and blame the user's word
      // list for what is actually a broken payload.
      expect(
        () => LevelReport.fromJson({'levels': 'nonsense'}),
        throwsA(anything),
      );
    });
  });

  group('LevelProgress — the numbers behind the two-layer bar', () {
    test('unmastered is seen minus mastered, notSeen is total minus seen', () {
      const progress = LevelProgress(
        level: 'N3',
        total: 200,
        seen: 120,
        mastered: 90,
      );
      expect(progress.unmastered, 30);
      expect(progress.notSeen, 80);
      expect(progress.masteredRatio, closeTo(0.45, 1e-9));
      expect(progress.seenRatio, closeTo(0.6, 1e-9));
    });

    test('clamps a server inconsistency instead of going negative', () {
      // mastered > seen is possible when the server counts a term as mastered
      // without recording the sighting; the bar must not draw backwards.
      const progress = LevelProgress(
        level: 'N1',
        total: 10,
        seen: 4,
        mastered: 7,
      );
      expect(progress.unmastered, 0);
      expect(progress.notSeen, 6);
    });

    test('ratios are 0 for an empty level, not NaN', () {
      const progress = LevelProgress(
        level: 'N1',
        total: 0,
        seen: 0,
        mastered: 0,
      );
      expect(progress.masteredRatio, 0);
      expect(progress.seenRatio, 0);
      expect(progress.masteredRatio.isNaN, isFalse);
    });
  });

  group('LevelReportKind.levelLabel — server codes to on-screen labels', () {
    test('TOPIK A/B/C become the two-level bands the web panel shows', () {
      expect(LevelReportKind.topik.levelLabel('A'), '1-2');
      expect(LevelReportKind.topik.levelLabel('B'), '3-4');
      expect(LevelReportKind.topik.levelLabel('C'), '5-6');
    });

    test('TOPIK passes an unknown code through rather than dropping it', () {
      expect(LevelReportKind.topik.levelLabel('D'), 'D');
    });

    test('HSK 3.0 collapses level 7 into the 7-9 band', () {
      expect(LevelReportKind.hsk3.levelLabel('7'), 'HSK 7-9');
      expect(LevelReportKind.hsk3.levelLabel('3'), 'HSK 3');
    });

    test('HSK 2.0 has no 7-9 band', () {
      expect(LevelReportKind.hsk2.levelLabel('7'), 'HSK 7');
    });

    test('Thai levels are word-count buckets', () {
      expect(LevelReportKind.thai.levelLabel('500'), '500 words');
    });

    test('JLPT and CEFR codes read as-is', () {
      expect(LevelReportKind.jlpt.levelLabel('N3'), 'N3');
      expect(LevelReportKind.cefr.levelLabel('B2'), 'B2');
    });
  });

  group('levelReportKindsFor — which report a language offers', () {
    test('Japanese offers JLPT', () {
      expect(levelReportKindsFor('Japanese'), [LevelReportKind.jlpt]);
    });

    test('Chinese offers both HSK versions, 2.0 before 3.0', () {
      expect(levelReportKindsFor('Chinese'), [
        LevelReportKind.hsk2,
        LevelReportKind.hsk3,
      ]);
    });

    test('matches native-script language names too', () {
      expect(levelReportKindsFor('日本語'), [LevelReportKind.jlpt]);
      expect(levelReportKindsFor('中文'), [
        LevelReportKind.hsk2,
        LevelReportKind.hsk3,
      ]);
    });

    test('is case- and whitespace-insensitive', () {
      expect(levelReportKindsFor('  KOREAN '), [LevelReportKind.topik]);
    });

    test('offers nothing for a language with no graded list', () {
      expect(levelReportKindsFor('Vietnamese'), isEmpty);
      expect(levelReportKindsFor(''), isEmpty);
    });

    test('every endpoint is a bare path segment', () {
      // The URL is /stats/<endpoint>_data, so a stray character here is a
      // silent 404 rather than a compile error.
      for (final kind in LevelReportKind.values) {
        expect(
          kind.endpoint,
          matches(RegExp(r'^[a-z0-9]+$')),
          reason: '${kind.name} endpoint must be a bare path segment',
        );
      }
    });
  });

  group('webPeriodFor — mobile period chips to server period strings', () {
    test('week maps to the 7-day window', () {
      expect(webPeriodFor(StatsPeriod.week), '7days');
    });

    test('every longer period maps to monthly, the longest bucket offered', () {
      for (final period in [
        StatsPeriod.month,
        StatsPeriod.quarter,
        StatsPeriod.year,
        StatsPeriod.all,
      ]) {
        expect(webPeriodFor(period), 'monthly', reason: '$period');
      }
    });
  });

  group('TermStatusGroup.forStatus — the server status codes', () {
    test('0 is unknown, 1-5 are vague, 98 ignored, 99 mastered', () {
      expect(TermStatusGroup.forStatus(0), TermStatusGroup.unknown);
      for (var status = 1; status <= 5; status++) {
        expect(
          TermStatusGroup.forStatus(status),
          TermStatusGroup.vague,
          reason: 'status $status',
        );
      }
      expect(TermStatusGroup.forStatus(98), TermStatusGroup.ignored);
      expect(TermStatusGroup.forStatus(99), TermStatusGroup.mastered);
    });

    test('codes outside those ranges land in other, not a real bucket', () {
      for (final status in [6, 50, 97, 100, -1]) {
        expect(
          TermStatusGroup.forStatus(status),
          TermStatusGroup.other,
          reason: 'status $status',
        );
      }
    });
  });

  group('TermSummary — the web Summary panel', () {
    test('parses the documented payload', () {
      final summary = TermSummary.fromJson({
        'total_terms': 1234,
        'recent_by_status': {'0': 3, '1': 2, '99': 5},
        'recent_label': 'Last 7 days',
        'cumulative_by_status': {'0': 100, '99': 400},
      });

      expect(summary.totalTerms, 1234);
      expect(summary.recentLabel, 'Last 7 days');
      expect(summary.recentByStatus, {0: 3, 1: 2, 99: 5});
      expect(summary.recentTotal, 10);
      expect(summary.cumulativeByStatus[99], 400);
    });

    test('buckets statuses into the panel groups', () {
      final summary = TermSummary.fromJson({
        'recent_by_status': {
          '0': 3,
          '1': 2,
          '4': 5,
          '98': 1,
          '99': 7,
          '42': 9,
        },
      });

      final grouped = summary.group(summary.recentByStatus);
      expect(grouped[TermStatusGroup.unknown], 3);
      expect(grouped[TermStatusGroup.vague], 7); // 2 + 5
      expect(grouped[TermStatusGroup.ignored], 1);
      expect(grouped[TermStatusGroup.mastered], 7);
      expect(grouped[TermStatusGroup.other], 9);
    });

    test('falls back to "Recent" for a missing, blank or non-string label', () {
      expect(TermSummary.fromJson(const {}).recentLabel, 'Recent');
      expect(TermSummary.fromJson({'recent_label': '   '}).recentLabel, 'Recent');
      expect(TermSummary.fromJson({'recent_label': 7}).recentLabel, 'Recent');
    });

    test('a non-map by_status does not throw', () {
      final summary = TermSummary.fromJson({'recent_by_status': 'nonsense'});
      expect(summary.recentByStatus, isEmpty);
      expect(summary.recentTotal, 0);
    });

    test('a status key that is not a number is skipped', () {
      final summary = TermSummary.fromJson({
        'recent_by_status': {'abc': 5, '3': 4},
      });
      expect(summary.recentByStatus, {3: 4});
    });
  });

  group('TermTrendPoint.listFromJson — chart and heatmap buckets', () {
    test('sorts by date so the line chart is monotonic', () {
      final points = TermTrendPoint.listFromJson([
        {'date': '2026-03-05', 'count': 5},
        {'date': '2026-01-01', 'count': 1},
        {'date': '2026-02-02', 'count': 3},
      ]);

      expect(points.map((p) => p.date.month).toList(), [1, 2, 3]);
      expect(points.map((p) => p.count).toList(), [1, 3, 5]);
    });

    test('skips rows with a missing or unparseable date', () {
      final points = TermTrendPoint.listFromJson([
        {'date': 'not-a-date', 'count': 1},
        {'count': 2},
        {'date': '2026-01-01', 'count': 1},
      ]);

      expect(points.length, 1);
      expect(points.single.date.year, 2026);
    });

    test('accepts numeric-string counts', () {
      final points = TermTrendPoint.listFromJson([
        {'date': '2026-01-01', 'count': '42'},
      ]);
      expect(points.single.count, 42);
    });

    test('a non-list payload yields no points', () {
      expect(TermTrendPoint.listFromJson(null), isEmpty);
      expect(TermTrendPoint.listFromJson('nope'), isEmpty);
    });
  });

  group('GrammarExample.fromJson — match ranges are clamped to the sentence', () {
    test('keeps a well-formed match', () {
      final example = GrammarExample.fromJson({
        'sentence': '私は日本語を勉強します',
        'matches': [
          {'start': 2, 'end': 5},
        ],
      });

      expect(example.matches.single.start, 2);
      expect(example.matches.single.end, 5);
    });

    test('clamps an end past the sentence instead of throwing RangeError', () {
      final example = GrammarExample.fromJson({
        'sentence': 'abc',
        'matches': [
          {'start': 1, 'end': 999},
        ],
      });

      expect(example.matches.single.start, 1);
      expect(example.matches.single.end, 3);
    });

    test('clamps a negative start to 0', () {
      final example = GrammarExample.fromJson({
        'sentence': 'abc',
        'matches': [
          {'start': -5, 'end': 2},
        ],
      });

      expect(example.matches.single.start, 0);
      expect(example.matches.single.end, 2);
    });

    test('drops empty, inverted and out-of-range matches', () {
      final example = GrammarExample.fromJson({
        'sentence': 'abc',
        'matches': [
          {'start': 2, 'end': 2}, // empty
          {'start': 3, 'end': 1}, // inverted
          {'start': 99, 'end': 100}, // entirely past the end
        ],
      });

      expect(example.matches, isEmpty);
    });

    test('sorts matches so the span builder walks forwards', () {
      final example = GrammarExample.fromJson({
        'sentence': 'abcdefgh',
        'matches': [
          {'start': 5, 'end': 6},
          {'start': 1, 'end': 2},
        ],
      });

      expect(example.matches.map((m) => m.start).toList(), [1, 5]);
    });

    test('skips a match whose offsets are not numbers', () {
      final example = GrammarExample.fromJson({
        'sentence': 'abc',
        'matches': [
          {'start': 'x', 'end': 2},
          {'start': 0, 'end': 1},
        ],
      });

      expect(example.matches.length, 1);
      expect(example.matches.single.start, 0);
    });
  });

  group('GrammarPoint.fromJson', () {
    test('trims the name and drops examples with no sentence', () {
      final point = GrammarPoint.fromJson({
        'name': '  〜ている  ',
        'level': 'N4',
        'desc': 'progressive',
        'examples': [
          {'sentence': '', 'matches': const []},
          {'sentence': '食べている', 'matches': const []},
        ],
      });

      expect(point.name, '〜ている');
      expect(point.level, 'N4');
      expect(point.desc, 'progressive');
      expect(point.examples.length, 1);
      expect(point.examples.single.sentence, '食べている');
    });

    test('level and desc are null when the rule library omits them', () {
      final point = GrammarPoint.fromJson({
        'name': 'plain',
        'examples': const [],
      });

      expect(point.level, isNull);
      expect(point.desc, isNull);
      expect(point.examples, isEmpty);
    });

    test('a blank level or desc is treated as absent, not as a label', () {
      final point = GrammarPoint.fromJson({
        'name': 'x',
        'level': '  ',
        'desc': '',
      });

      expect(point.level, isNull);
      expect(point.desc, isNull);
    });

    test('a non-list examples value fails loudly instead of dropping points', () {
      // Same reasoning as the level report: the grammar screen shows an error
      // state, so a malformed payload must reach it rather than render as
      // "no grammar points on this page", which would be a lie.
      expect(
        () => GrammarPoint.fromJson({'name': 'x', 'examples': 'nonsense'}),
        throwsA(anything),
      );
    });
  });

  group('GrammarNotifier.pageText — the text sent to the analyser', () {
    PageData pageWith(List<String> paragraphs) => PageData(
      bookId: 1,
      currentPage: 1,
      pageCount: 1,
      paragraphs: [
        for (var i = 0; i < paragraphs.length; i++)
          Paragraph(
            id: i,
            textItems: [
              TextItem(
                text: paragraphs[i],
                statusClass: '',
                sentenceId: 0,
                paragraphId: i,
                isStartOfSentence: true,
                order: 0,
              ),
            ],
          ),
      ],
    );

    test('joins paragraphs with newlines, not spaces', () {
      // Subtitle and transcript lines carry no sentence-ending punctuation, so
      // joining with spaces would collapse them into one pseudo-sentence.
      expect(
        GrammarNotifier.pageText(pageWith(['おはよう', 'こんにちは'])),
        'おはよう\nこんにちは',
      );
    });

    test('skips empty paragraphs so they cannot become blank lines', () {
      expect(
        GrammarNotifier.pageText(pageWith(['あ', '', '   ', 'い'])),
        'あ\nい',
      );
    });

    test('trims each paragraph', () {
      expect(GrammarNotifier.pageText(pageWith(['  x  '])), 'x');
    });

    test('an all-empty page yields an empty string, not a stray newline', () {
      expect(GrammarNotifier.pageText(pageWith(['', '  '])), '');
    });

    test('a page with no paragraphs is empty', () {
      expect(GrammarNotifier.pageText(pageWith(const [])), '');
    });
  });
}
