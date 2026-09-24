import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/network_providers.dart';
import '../models/level_report.dart';

/// The graded word lists the server can report against, one per language it
/// recognises.  Mirrors the buttons the web stats page shows next to its
/// language selector (`data-jp` / `data-en` / ... on the option).
enum LevelReportKind {
  jlpt('jlpt', 'JLPT', 'Japanese'),
  cefr('cefr', 'CEFR', 'English'),
  topik('topik', 'TOPIK', 'Korean'),
  dele('dele', 'DELE', 'Spanish'),
  russian('russian', 'Russian CEFR', 'Russian'),
  german('german', 'German CEFR', 'German'),
  thai('thai', 'Thai Freq', 'Thai'),
  french('french', 'French CEFR', 'French'),
  arabic('arabic', 'Arabic CEFR', 'Arabic'),
  hsk2('hsk2', 'HSK 2.0', 'Chinese'),
  hsk3('hsk3', 'HSK 3.0', 'Chinese');

  /// Path segment: the endpoint is `/stats/<endpoint>_data`.
  final String endpoint;
  final String label;
  final String language;

  const LevelReportKind(this.endpoint, this.label, this.language);

  /// How a level code reads on screen.  The server sends bare codes -- the
  /// web panel relabels them the same way.
  String levelLabel(String level) {
    switch (this) {
      case LevelReportKind.topik:
        return const {'A': '1-2', 'B': '3-4', 'C': '5-6'}[level] ?? level;
      case LevelReportKind.hsk3:
        return level == '7' ? 'HSK 7-9' : 'HSK $level';
      case LevelReportKind.hsk2:
        return 'HSK $level';
      case LevelReportKind.thai:
        return '$level words';
      default:
        return level;
    }
  }

  /// One-line description of where the word list comes from, shown under the
  /// card title.
  String get source {
    switch (this) {
      case LevelReportKind.jlpt:
        return 'Japanese · N5-N1 · data: OpenJLPT';
      case LevelReportKind.cefr:
        return 'English · A1-C2 · data: CEFR word list';
      case LevelReportKind.topik:
        return 'Korean · TOPIK I-II';
      case LevelReportKind.dele:
        return 'Spanish · A1-C2 · DELE vocabulary';
      case LevelReportKind.russian:
        return 'Russian · A1-C2';
      case LevelReportKind.german:
        return 'German · A1-C2';
      case LevelReportKind.thai:
        return 'Thai · frequency buckets';
      case LevelReportKind.french:
        return 'French · A1-C2';
      case LevelReportKind.arabic:
        return 'Arabic · A1-C2 · data: KELLY Project';
      case LevelReportKind.hsk2:
        return 'Chinese · HSK 2.0 levels 1-6';
      case LevelReportKind.hsk3:
        return 'Chinese · HSK 3.0 levels 1-9';
    }
  }
}

/// Which reports make sense for a language, decided by its name -- the only
/// thing the client knows about a language.  The web page does the same for
/// every language except Japanese and Korean, where it can also see the
/// parser type.
List<LevelReportKind> levelReportKindsFor(String languageName) {
  final name = languageName.trim().toLowerCase();
  if (name.isEmpty) return const [];

  bool has(String needle) => name.contains(needle);

  if (has('japanese') || has('日本語') || has('日语') || has('日語')) {
    return const [LevelReportKind.jlpt];
  }
  if (has('korean') || has('한국어') || has('韩语') || has('韓語')) {
    return const [LevelReportKind.topik];
  }
  if (has('chinese') || has('mandarin') || has('中文') || has('汉语') ||
      has('漢語')) {
    return const [LevelReportKind.hsk2, LevelReportKind.hsk3];
  }
  if (name == 'english') return const [LevelReportKind.cefr];
  if (name == 'spanish') return const [LevelReportKind.dele];
  if (name == 'russian') return const [LevelReportKind.russian];
  if (name == 'german') return const [LevelReportKind.german];
  if (name == 'thai') return const [LevelReportKind.thai];
  if (name == 'french') return const [LevelReportKind.french];
  if (name == 'arabic') return const [LevelReportKind.arabic];
  return const [];
}

typedef LevelReportQuery = ({LevelReportKind kind, int langId});

final levelReportProvider =
    FutureProvider.family<LevelReport, LevelReportQuery>((ref, query) async {
      return ref
          .watch(contentServiceProvider)
          .getLevelReport(
            kind: query.kind.endpoint,
            langId: query.langId,
          );
    });
