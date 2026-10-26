import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'html_parser.dart';
import 'local_dict.dart';
import 'session_manager.dart';

enum AIType { translation, virtualDictionary }

/// 后台刷新后与当前列表比对：字典名/URL 模板/AI 属性全一致才算没变化，
/// 决定词典弹窗是否需要重建 UI。
bool sameDictionaries(List<DictionarySource> a, List<DictionarySource> b) {
  if (a.length != b.length) return false;
  String sig(DictionarySource d) =>
      '${d.name}\u0000${d.urlTemplate}\u0000${d.isAI}\u0000${d.aiType}'
      '\u0000${d.isLocal}';
  for (var i = 0; i < a.length; i++) {
    if (sig(a[i]) != sig(b[i])) return false;
  }
  return true;
}

class DictionarySource {
  final String name;
  final String urlTemplate;
  final bool isAI;
  final AIType? aiType;

  /// 本地（服务器词典池）词典：此时 [urlTemplate] 是池里的 `.db` 文件名，
  /// 不是 URL，必须走 `/read/localdict/...` 查询（见 `local_dict.dart`）。
  final bool isLocal;

  const DictionarySource({
    required this.name,
    required this.urlTemplate,
    this.isAI = false,
    this.aiType,
    this.isLocal = false,
  });

  /// 老缓存里没有 `isLocal` 字段，靠模板形状兜底识别。
  bool get isLocalDictionary => isLocal || looksLikeLocalDictFile(urlTemplate);

  factory DictionarySource.fromJson(Map<String, dynamic> json) {
    final urlTemplate = json['urlTemplate'] as String? ?? '';
    final isLocal =
        json['isLocal'] as bool? ?? looksLikeLocalDictFile(urlTemplate);
    var name = json['name'] as String? ?? '';
    // 旧版本把本地词典的名字解析成了兜底的 "Dictionary"（文件名当 URL 解析
    // 会抛错），这里按文件名重建一个可读的名字，免得用户看到的表头全是
    // "Dictionary"。
    if (isLocal && (name.isEmpty || name == 'Dictionary')) {
      name = localDictFallbackName(urlTemplate);
    }
    return DictionarySource(
      name: name,
      urlTemplate: urlTemplate,
      isAI: json['isAI'] as bool? ?? false,
      aiType: json['aiType'] != null
          ? AIType.values.firstWhere(
              (e) => e.toString() == json['aiType'],
              orElse: () => AIType.translation,
            )
          : null,
      isLocal: isLocal,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'urlTemplate': urlTemplate,
      'isAI': isAI,
      'aiType': aiType?.toString(),
      'isLocal': isLocal,
    };
  }
}

class DictionaryService {
  final Map<int, List<DictionarySource>> _dictionariesCache = {};
  final Map<int, List<DictionarySource>> _sentenceDictionariesCache = {};
  final Map<String, InAppWebViewController> _webviewCache = {};
  final HtmlParser _htmlParser;
  final Future<String?> Function(int) _fetchLanguageSettingsHtml;

  DictionaryService({
    required Future<String?> Function(int) fetchLanguageSettingsHtml,
  }) : _htmlParser = HtmlParser(),
       _fetchLanguageSettingsHtml = fetchLanguageSettingsHtml;

  String buildUrl(String term, String urlTemplate) {
    final encodedTerm = Uri.encodeComponent(term);
    return urlTemplate
        .replaceAll('[LUTE]', encodedTerm)
        .replaceAll('{term}', encodedTerm)
        .replaceAll('{sentence}', encodedTerm);
  }

  /// 词典弹窗里该为 [dictionary] 加载哪个地址。
  ///
  /// 在线词典就是把词填进模板；本地词典的模板是服务器池里的文件名，得换成
  /// 服务端的查询路由，否则 WebView 会拿文件名当域名去解析
  /// （`net::ERR_NAME_NOT_RESOLVED`）。[serverUrl] 由调用方从设置里取，
  /// 服务层本身不持有配置。
  String buildDictionaryUrl({
    required String term,
    required DictionarySource dictionary,
    required int languageId,
    required String serverUrl,
  }) {
    if (dictionary.isLocalDictionary) {
      return buildLocalDictUrl(
        serverUrl: serverUrl,
        languageId: languageId,
        fileName: dictionary.urlTemplate,
        term: term,
      );
    }
    return buildUrl(term, dictionary.urlTemplate);
  }

  Future<List<DictionarySource>> getDictionariesForLanguage(
    int languageId,
  ) async {
    if (_dictionariesCache.containsKey(languageId)) {
      return _dictionariesCache[languageId]!;
    }

    final prefs = await SharedPreferences.getInstance();
    final dictionariesJson = prefs.getString('dictionaries_$languageId');

    if (dictionariesJson != null) {
      final List<dynamic> decoded = jsonDecode(dictionariesJson);
      final dictionaries = decoded
          .map(
            (json) => DictionarySource.fromJson(json as Map<String, dynamic>),
          )
          .toList();

      _dictionariesCache[languageId] = dictionaries;
      return dictionaries;
    }

    final htmlContent = await _fetchLanguageSettingsHtml(languageId) ?? '';
    if (htmlContent.isNotEmpty) {
      final dictionaries = _htmlParser.parseLanguageDictionaries(htmlContent);
      if (dictionaries.isNotEmpty) {
        await setDictionariesForLanguage(languageId, dictionaries);
        return dictionaries;
      }
    }

    return [];
  }

  Future<List<DictionarySource>> getSentenceDictionariesForLanguage(
    int languageId,
  ) async {
    if (_sentenceDictionariesCache.containsKey(languageId)) {
      return _sentenceDictionariesCache[languageId]!;
    }

    final prefs = await SharedPreferences.getInstance();
    final dictionariesJson = prefs.getString(
      'sentence_dictionaries_$languageId',
    );

    if (dictionariesJson != null) {
      final List<dynamic> decoded = jsonDecode(dictionariesJson);
      final dictionaries = decoded
          .map(
            (json) => DictionarySource.fromJson(json as Map<String, dynamic>),
          )
          .toList();

      _sentenceDictionariesCache[languageId] = dictionaries;
      return dictionaries;
    }

    final htmlContent = await _fetchLanguageSettingsHtml(languageId) ?? '';
    if (htmlContent.isNotEmpty) {
      final dictionaries = _htmlParser.parseSentenceDictionaries(htmlContent);
      if (dictionaries.isNotEmpty) {
        await setSentenceDictionariesForLanguage(languageId, dictionaries);
        return dictionaries;
      }
    }

    return [];
  }

  Future<void> setDictionariesForLanguage(
    int languageId,
    List<DictionarySource> dictionaries,
  ) async {
    _dictionariesCache[languageId] = dictionaries;
    final prefs = await SharedPreferences.getInstance();
    final dictionariesJson = jsonEncode(
      dictionaries.map((d) => d.toJson()).toList(),
    );
    await prefs.setString('dictionaries_$languageId', dictionariesJson);
  }

  Future<void> setSentenceDictionariesForLanguage(
    int languageId,
    List<DictionarySource> dictionaries,
  ) async {
    _sentenceDictionariesCache[languageId] = dictionaries;
    final prefs = await SharedPreferences.getInstance();
    final dictionariesJson = jsonEncode(
      dictionaries.map((d) => d.toJson()).toList(),
    );
    await prefs.setString(
      'sentence_dictionaries_$languageId',
      dictionariesJson,
    );
  }

  Future<void> clearDictionariesForLanguage(int languageId) async {
    _dictionariesCache.remove(languageId);
    _sentenceDictionariesCache.remove(languageId);

    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove('dictionaries_$languageId'),
      prefs.remove('sentence_dictionaries_$languageId'),
    ]);
  }

  /// 从服务器重拉语言设置页并覆盖本地词典缓存。
  ///
  /// 后台静默刷新用：网络失败或解析为空时返回 false 且**不清空现有缓存**
  /// —— 不能让一次抖动把用户已配置的词典冲掉。部分成功（某类列表为空）
  /// 只覆盖非空的那类。
  Future<bool> refreshDictionariesForLanguage(int languageId) async {
    String htmlContent;
    try {
      htmlContent = await _fetchLanguageSettingsHtml(languageId) ?? '';
    } catch (_) {
      return false;
    }
    if (htmlContent.isEmpty) return false;

    final dictionaries = _htmlParser.parseLanguageDictionaries(htmlContent);
    final sentenceDictionaries = _htmlParser.parseSentenceDictionaries(
      htmlContent,
    );
    if (dictionaries.isEmpty && sentenceDictionaries.isEmpty) return false;

    if (dictionaries.isNotEmpty) {
      await setDictionariesForLanguage(languageId, dictionaries);
    }
    if (sentenceDictionaries.isNotEmpty) {
      await setSentenceDictionariesForLanguage(
        languageId,
        sentenceDictionaries,
      );
    }
    return true;
  }

  Future<String?> getLastUsedDictionary(int languageId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_dictionary_$languageId');
  }

  Future<String?> getLastUsedSentenceDictionary(int languageId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_sentence_dictionary_$languageId');
  }

  Future<void> rememberLastUsedDictionary(
    int languageId,
    String dictionaryName,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_dictionary_$languageId', dictionaryName);
  }

  Future<void> rememberLastUsedSentenceDictionary(
    int languageId,
    String dictionaryName,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'last_sentence_dictionary_$languageId',
      dictionaryName,
    );
  }

  static const int defaultPopupHeight = 300;
  static const int minPopupHeight = 150;
  static const int maxPopupHeight = 600;
  static const int popupHeightStep = 50;

  /// 弹窗高度存的是「手机等效高度」，这是换算基准的 webview 宽度。
  ///
  /// 有道这类词典页会随 CSS 视口宽度整体放大：Leaf 5C 是 300dpi 的屏
  /// （dpr 1.875），逻辑宽 674，弹窗里的 webview 宽 634 CSS px，而手机只有
  /// 440 左右 —— 同一个页面在这台机器上文字大 ~1.5 倍。高度却是写死的
  /// 300 逻辑像素，于是只能露出手机上 2/3 的内容，翻译结果被顶到折叠线
  /// 以下，必须手动滚动才看得到（2026-09-28 Leaf 5C 反馈）。
  static const int referenceWebviewWidth = 440;

  /// 页面放大倍数略大于视口宽度比（Leaf 5C 实测：宽度比 1.44、字号比 1.50），
  /// 留一点余量，免得换算完还差最后一行。
  static const double popupHeightHeadroom = 1.05;

  /// 把「手机等效高度」换算成 [webviewWidth] 宽设备上的实际高度。
  ///
  /// 只放大、不缩小：手机（webview ≤ 440）行为完全不变，宽视口设备按比例
  /// 加高，让两边露出的内容量一致（Leaf 5C：300 → 454）。
  static int resolvePopupHeight(int height, double webviewWidth) {
    if (webviewWidth <= referenceWebviewWidth) return height;
    final scale =
        (webviewWidth / referenceWebviewWidth) * popupHeightHeadroom;
    return (height * scale).round().clamp(minPopupHeight, maxPopupHeight);
  }

  Future<int> getSentenceTranslationPopupHeight() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('sentence_translation_popup_height') ??
        defaultPopupHeight;
  }

  Future<void> setSentenceTranslationPopupHeight(int height) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sentence_translation_popup_height', height);
  }

  Future<bool> getSentenceTranslationStartCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('sentence_translation_start_collapsed') ?? true;
  }

  Future<void> setSentenceTranslationStartCollapsed(bool collapsed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sentence_translation_start_collapsed', collapsed);
  }

  static const int defaultSplitRatio = 7;
  static const int minSplitRatio = 5;
  static const int maxSplitRatio = 8;

  Future<int> getSentenceReaderSplitRatio() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('sentence_reader_split_ratio') ?? defaultSplitRatio;
  }

  Future<void> setSentenceReaderSplitRatio(int ratio) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sentence_reader_split_ratio', ratio);
  }

  String getWebviewCacheKey(String dictionaryName, String term) {
    return '${dictionaryName}_${term.hashCode}';
  }

  /// 词典 WebView 的渲染设置。
  ///
  /// [localDictionary] 为真时**必须**关掉 wide viewport：服务端
  /// `read/localdict.html` 没有 `<meta name=viewport>`，Android WebView 默认
  /// 按 980px 宽布局再整体缩放到控件宽度（400dp 左右），15px 的字实际只剩
  /// 约 6dp —— 手机上就是"字很小看不清"。关掉后布局宽度 = 控件宽度，
  /// 字号回到正常的 15px。第三方词典页自带 viewport meta，保持默认行为。
  static InAppWebViewSettings webviewSettings({
    required bool localDictionary,
  }) {
    return InAppWebViewSettings(
      sharedCookiesEnabled: true,
      cacheEnabled: true,
      javaScriptEnabled: true,
      userAgent:
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      useWideViewPort: !localDictionary,
      loadWithOverviewMode: !localDictionary,
    );
  }

  InAppWebViewController? getCachedWebview(String cacheKey) {
    return _webviewCache[cacheKey];
  }

  /// 把 App 的多用户会话 cookie 写进 WebView 的 cookie store。
  ///
  /// 词典弹窗里只有首个请求能带上自定义 header（`URLRequest.headers`）；
  /// 服务器页面自己发起的后续导航（本地词典的交叉引用、主题 CSS 之外的
  /// 子资源）带不上，多用户模式下会被 302 到 /login。cookie 装进 store
  /// 后这段链路才是通的。
  static Future<void> installSessionCookie(String serverUrl) async {
    final cookie = SessionManager.sessionCookie;
    if (cookie == null || cookie.isEmpty) return;
    final separator = cookie.indexOf('=');
    if (separator <= 0) return;
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.host.isEmpty) return;
    try {
      await CookieManager.instance().setCookie(
        url: WebUri(serverUrl),
        name: cookie.substring(0, separator),
        value: cookie.substring(separator + 1),
        path: '/',
        domain: uri.host,
        isSecure: uri.scheme == 'https',
        isHttpOnly: true,
      );
    } catch (_) {
      // 装 cookie 失败只影响页内跳转，首个请求仍有 Authorization/Cookie header。
    }
  }

  void cacheWebview(String cacheKey, InAppWebViewController controller) {
    _webviewCache[cacheKey] = controller;
  }

  void clearCache() {
    _webviewCache.clear();
  }
}
