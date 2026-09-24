import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/language_data_provider.dart';
import '../../../shared/providers/network_providers.dart';
import '../models/term_activity.dart';
import 'stats_provider.dart';

/// The period strings `/stats/term_data` understands.
///
/// The web panel offers Today / 7 days / Monthly; the mobile stats screen's
/// period chips are week / month / quarter / year / all.  Week maps to the
/// 7-day window, everything longer to the monthly buckets -- there is no
/// server-side bucket for "90 days", and inventing one client-side would
/// disagree with the web page.
String webPeriodFor(StatsPeriod period) {
  return period == StatsPeriod.week ? '7days' : 'monthly';
}

/// Id of the language the stats screen is filtered to, or null for "all".
///
/// The stats screen filters by language *name* (it only ever had names to work
/// with); the term and level endpoints want an id, so the two are matched
/// here, case-insensitively.
final statsSelectedLangIdProvider = Provider<int?>((ref) {
  final selected = ref.watch(statsProvider).value?.selectedLanguage;
  if (selected == null) return null;

  final languages = ref.watch(languageListProvider).value;
  if (languages == null) return null;

  final wanted = selected.language.trim().toLowerCase();
  for (final language in languages) {
    if (language.name.trim().toLowerCase() == wanted) return language.id;
  }
  return null;
});

typedef TermActivityQuery = ({String period, int? langId});

/// Term trends, mastered terms, activity heatmap and the status summary.
final termActivityProvider =
    FutureProvider.family<TermActivity, TermActivityQuery>((ref, query) async {
      return ref
          .watch(contentServiceProvider)
          .getTermActivity(period: query.period, langId: query.langId);
    });
