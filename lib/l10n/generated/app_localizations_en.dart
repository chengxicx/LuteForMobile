// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Song Mobile';

  @override
  String get navReader => 'Reader';

  @override
  String get navBooks => 'Books';

  @override
  String get navGrammar => 'Grammar';

  @override
  String get navReview => 'Review';

  @override
  String get navStats => 'Stats';

  @override
  String get navTerms => 'Terms';

  @override
  String get navHelp => 'Help';

  @override
  String get navSettings => 'Settings';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonOk => 'OK';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonError => 'Error';

  @override
  String get commonClose => 'Close';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionServer => 'Server';

  @override
  String get settingsSectionReading => 'Reading';

  @override
  String get settingsSectionStorage => 'Storage';

  @override
  String get settingsSectionAppearance => 'Appearance';

  @override
  String get settingsUiLanguage => 'Interface language';

  @override
  String get settingsUiLanguageDesc =>
      'Language used for the app interface. Saved on this device only — independent of the web settings page.';

  @override
  String get readerPrevChapter => 'Prev chapter';

  @override
  String get readerNextChapter => 'Next chapter';

  @override
  String get readerEndOfChapter => 'End of chapter';

  @override
  String get readerEndOfBook => 'End of book';

  @override
  String get readerContents => 'Contents';

  @override
  String get readerChaptersLoading => 'Loading chapters…';

  @override
  String get readerChaptersUnavailable => 'Chapter list unavailable offline';
}
