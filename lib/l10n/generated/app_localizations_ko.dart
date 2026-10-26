// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'Song Mobile';

  @override
  String get navReader => '리더';

  @override
  String get navBooks => '책장';

  @override
  String get navGrammar => '문법';

  @override
  String get navReview => '복습';

  @override
  String get navStats => '통계';

  @override
  String get navTerms => '용어';

  @override
  String get navHelp => '도움말';

  @override
  String get navSettings => '설정';

  @override
  String get commonCancel => '취소';

  @override
  String get commonOk => '확인';

  @override
  String get commonSave => '저장';

  @override
  String get commonDelete => '삭제';

  @override
  String get commonRetry => '재시도';

  @override
  String get commonLoading => '불러오는 중…';

  @override
  String get commonError => '오류';

  @override
  String get commonClose => '닫기';

  @override
  String get settingsTitle => '설정';

  @override
  String get settingsSectionServer => '서버';

  @override
  String get settingsSectionReading => '읽기';

  @override
  String get settingsSectionStorage => '저장소';

  @override
  String get settingsSectionAppearance => '모양';

  @override
  String get settingsUiLanguage => '인터페이스 언어';

  @override
  String get settingsUiLanguageDesc =>
      '앱 인터페이스에 사용할 언어입니다. 이 기기에만 저장되며 웹 설정 페이지와 독립적입니다.';

  @override
  String get readerPrevChapter => '이전 장';

  @override
  String get readerNextChapter => '다음 장';

  @override
  String get readerEndOfChapter => '이 장의 끝';

  @override
  String get readerEndOfBook => '이 책의 끝';

  @override
  String get readerContents => '목차';

  @override
  String get readerChaptersLoading => '장을 불러오는 중…';

  @override
  String get readerChaptersUnavailable => '오프라인에서는 장 목록을 불러올 수 없습니다';
}
