// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Song Mobile';

  @override
  String get navReader => 'リーダー';

  @override
  String get navBooks => '本棚';

  @override
  String get navGrammar => '文法';

  @override
  String get navReview => '復習';

  @override
  String get navStats => '統計';

  @override
  String get navTerms => '用語';

  @override
  String get navHelp => 'ヘルプ';

  @override
  String get navSettings => '設定';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonOk => 'OK';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '削除';

  @override
  String get commonRetry => '再試行';

  @override
  String get commonLoading => '読み込み中…';

  @override
  String get commonError => 'エラー';

  @override
  String get commonClose => '閉じる';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsSectionServer => 'サーバー';

  @override
  String get settingsSectionReading => '読む';

  @override
  String get settingsSectionStorage => 'ストレージ';

  @override
  String get settingsSectionAppearance => '外観';

  @override
  String get settingsUiLanguage => '表示言語';

  @override
  String get settingsUiLanguageDesc =>
      'アプリのインターフェースに使用する言語。この端末にのみ保存され、ウェブの設定ページとは独立しています。';
}
