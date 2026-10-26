// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Song Mobile';

  @override
  String get navReader => '阅读';

  @override
  String get navBooks => '书架';

  @override
  String get navGrammar => '语法';

  @override
  String get navReview => '复习';

  @override
  String get navStats => '统计';

  @override
  String get navTerms => '术语';

  @override
  String get navHelp => '帮助';

  @override
  String get navSettings => '设置';

  @override
  String get commonCancel => '取消';

  @override
  String get commonOk => '确定';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '删除';

  @override
  String get commonRetry => '重试';

  @override
  String get commonLoading => '加载中…';

  @override
  String get commonError => '错误';

  @override
  String get commonClose => '关闭';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSectionServer => '服务器';

  @override
  String get settingsSectionReading => '阅读';

  @override
  String get settingsSectionStorage => '存储';

  @override
  String get settingsSectionAppearance => '外观';

  @override
  String get settingsUiLanguage => '界面语言';

  @override
  String get settingsUiLanguageDesc => '应用界面使用的语言。仅保存于本机，与网页端设置相互独立。';

  @override
  String get readerPrevChapter => '上一章';

  @override
  String get readerNextChapter => '下一章';

  @override
  String get readerEndOfChapter => '本章完';

  @override
  String get readerEndOfBook => '全书完';

  @override
  String get readerContents => '目录';

  @override
  String get readerChaptersLoading => '正在加载章节…';

  @override
  String get readerChaptersUnavailable => '离线时无法获取章节列表';
}
