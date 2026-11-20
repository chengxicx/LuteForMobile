import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dictionary_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../settings/providers/settings_provider.dart';

/// Web 端插件「看图背单词」（lute-picwords）的整页容器。
///
/// 页面是 `{serverUrl}/picwords/`，它继承 Lute 的 `base.html`，所以自带宽高的
/// 全站导航（logo + Book/Term/Setting 菜单 + 语言选择/搜索/主题按钮）。这里做
/// 三件事：
///  1. **去掉那圈 chrome**，只留插件自己的 `.pw-app` —— 手机视口本来就窄
///     （Leaf5C ≈ 674 CSS px），顶栏纯属浪费，而且 hover 式子菜单在触屏上
///     没法用；
///  2. **把 App 配色注入页面**。picwords 的调色板本来就架在 Song 的 token 上
///     （`--pw-ink: var(--font-color)`、`--pw-card: var(--panel-bg)` 等，见
///     picwords.css:9-17），换掉这几个变量整页就跟 App 的深浅色一致，不会
///     出现"深色 App 里弹出一张白纸"；
///  3. **复用 App 已有的 WebView 设施**，不重造：渲染设置与 UA 走
///     [DictionaryService.webviewSettings]、首请求凭证走
///     [SessionManager.authHeaders]、页内后续导航的会话走
///     [DictionaryService.installSessionCookie]、墨水屏白屏走
///     [DictionaryService.forceRepaint]。词卡「Sentence」面板里的 AI 页
///     （`sentence_translation.dart` 的 `/ai/sentence` WebView）用的是同一套。
class PicWordsScreen extends ConsumerStatefulWidget {
  const PicWordsScreen({super.key});

  @override
  ConsumerState<PicWordsScreen> createState() => _PicWordsScreenState();
}

class _PicWordsScreenState extends ConsumerState<PicWordsScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;

  /// 初始化时抓一次：设置页改服务器地址不该让一个已经打开的页面重载。
  late final String _serverUrl;
  late final String _pageUrl;

  /// 服务器可能部署在子路径（`https://host/lute/`），拦截判断要带上它。
  late final String _basePath;

  bool _firstLoadDone = false;
  bool _loginRequired = false;
  bool _leaving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _serverUrl = ref.read(settingsProvider).serverUrl;
    final base = _serverUrl.endsWith('/')
        ? _serverUrl.substring(0, _serverUrl.length - 1)
        : _serverUrl;
    _pageUrl = '$base/picwords/';

    var path = Uri.tryParse(base)?.path ?? '';
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    _basePath = path; // '' 或 '/lute'

    // 没有服务器地址时不能构造相对 URL（WebUri('/picwords/') 没有 scheme），
    // 直接把错误摆出来，比让 WebView 抛断言好。
    if (_serverUrl.isEmpty) {
      _loadError =
          'Set the server address in Settings \u203a Server, then try again.';
      _firstLoadDone = true;
    }

    // 首个主文档能带 header，页面自己发的 fetch/XHR 带不上 —— 必须在 WebView
    // 创建前把 session cookie 写进 cookie store，否则多用户模式下
    // /picwords/api/* 会被 302 到 /login。
    unawaited(DictionaryService.installSessionCookie(_serverUrl));
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// BOOX 上 WebView 切到后台再回来经常整页空白：渲染树还在、合成器不出帧。
  /// 与词卡/EPUB 章节页同一条解法。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final controller = _controller;
      if (controller != null) DictionaryService.forceRepaint(controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eInk = context.eInk;
    final surface = context.appColorScheme.background.surface;
    final script = _injectionScript(context, eInk: eInk);

    return PopScope(
      // 自己接管返回：先把页内发音停掉再 pop，否则退出后声音还在放。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to Review',
            onPressed: () => unawaited(_leave()),
          ),
          title: const Text('Picture Words'),
          // 不放刷新按钮：reload 会丢掉插件内存里的这一轮 session（剩余卡片
          // 直接消失，虽然答过的已经逐题写回服务端），而加载失败已经有 Retry。
        ),
        body: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: surface)),
            if (_serverUrl.isNotEmpty)
              Positioned.fill(child: _buildWebView(script)),
            if (!_firstLoadDone && _loadError == null && !_loginRequired)
              Positioned.fill(
                child: ColoredBox(
                  color: surface,
                  child: const LoadingIndicator(
                    message: 'Opening the picture album \u2026',
                  ),
                ),
              ),
            if (_loadError != null)
              Positioned.fill(
                child: ColoredBox(
                  color: surface,
                  child: ErrorDisplay(
                    icon: Icons.cloud_off,
                    title: 'Picture Words could not load',
                    message: _loadError!,
                    onRetry: _reload,
                  ),
                ),
              ),
            if (_loginRequired)
              Positioned.fill(
                child: ColoredBox(
                  color: surface,
                  child: Column(
                    children: [
                      const Expanded(
                        child: ErrorDisplay(
                          icon: Icons.person_off,
                          title: 'Sign-in required',
                          message:
                              'The server session has expired. '
                              'Log in again under Settings \u203a Server.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () => unawaited(_leave()),
                            child: const Text('Back to Review'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView(String script) {
    // 以 DictionaryService.webviewSettings 为基线（UA / cookie / 缓存 /
    // viewport 只维护一处），只在这里追加整页场景需要的几项。
    final base = DictionaryService.webviewSettings(localDictionary: false);

    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(_pageUrl),
        headers: SessionManager.authHeaders(),
      ),
      initialSettings: InAppWebViewSettings(
        sharedCookiesEnabled: base.sharedCookiesEnabled,
        cacheEnabled: base.cacheEnabled,
        javaScriptEnabled: base.javaScriptEnabled,
        userAgent: base.userAgent,
        useWideViewPort: base.useWideViewPort,
        loadWithOverviewMode: base.loadWithOverviewMode,
        // 布局交给页面自己的 620/860 断点，双指缩放只会把版式推乱。
        supportZoom: false,
        // 不开这个，shouldOverrideUrlLoading 根本不会被回调。
        useShouldOverrideUrlLoading: true,
        // listen 卡是定时自动播放的，默认的"必须用户手势"会让它没声音。
        mediaPlaybackRequiresUserGesture: false,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: script,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      // 不在 PageView 里，没有横向滑动要留给父级：必须 eager，否则 Flutter 会
      // 把指针事件缓存到抬手才一次性回放，滚动"不跟手"。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory(() => EagerGestureRecognizer()),
      },
      onWebViewCreated: (controller) {
        _controller = controller;
        unawaited(DictionaryService.installSessionCookie(_serverUrl));
      },
      onLoadStart: (controller, url) {
        // 重新登录后 cookie 会变，每次主文档开始都补一次（幂等、极快）。
        unawaited(DictionaryService.installSessionCookie(_serverUrl));
        if (url != null && _isLoginPath(_asUri(url))) _markLoginRequired();
      },
      onLoadStop: (controller, url) async {
        if (url != null && _isLoginPath(_asUri(url))) {
          _markLoginRequired();
          return;
        }
        if (mounted) {
          setState(() {
            _loadError = null;
            _firstLoadDone = true;
          });
        }
        // 再注入一次：页面后加载的样式可能排在我们前面。
        try {
          await controller.evaluateJavascript(source: _injectionScript(
            context,
            eInk: context.eInk,
          ));
        } catch (_) {
          // 页面正在导航；下次 loadStop 会补上。
        }
        DictionaryService.forceRepaint(controller);
      },
      onReceivedError: (controller, request, error) {
        // 只认「我们自己的那一页」的失败。被 [shouldOverrideUrlLoading] 取消
        // 的站内链接（/review/index 之类）也会走到这里，甚至带着一个上游
        // 假状态；那个 URL 的失败与当前文档无关，不能整页顶成错误。
        if (!_isOurPageRequest(request)) return;
        // CANCELLED 是自己发起的跳转/重载打断的，不是失败。
        if (error.type == WebResourceErrorType.CANCELLED) return;
        _fail(error.description);
      },
      onReceivedHttpError: (controller, request, response) {
        if (!_isOurPageRequest(request)) return;
        final status = response.statusCode ?? 0;
        if (status < 400) return;
        _fail(
          status == 404
              ? 'The Picture Words plugin is not installed on this server.'
              : 'The server answered with $status.',
        );
      },
      onReceivedHttpAuthRequest: _onHttpAuthRequest,
      shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
    );
  }

  // ---------------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------------

  void _reload() {
    setState(() {
      _loadError = null;
      _loginRequired = false;
    });
    final controller = _controller;
    if (controller != null) unawaited(controller.reload());
  }

  void _fail(String message) {
    if (!mounted || _loadError == message) return;
    setState(() {
      _loadError = message;
      _firstLoadDone = true;
    });
  }

  void _markLoginRequired() {
    if (!mounted || _loginRequired) return;
    setState(() {
      _loginRequired = true;
      _firstLoadDone = true;
    });
  }

  Future<void> _leave() async {
    if (_leaving) return; // 双击返回只 pop 一次
    _leaving = true;
    await _stopPageMedia();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// 退出前把页面正在放的发音停掉。
  ///
  /// 插件用 `new Audio(url)` 放 `/tts/` 返回的音频，那个对象不在 DOM 里，
  /// `querySelectorAll('audio')` 抓不到 —— 所以注入脚本在 document start 时
  /// 包了一层构造函数，把实例登记到 `window.__lutePwAudios`。250ms 超时兜底：
  /// 即便 JS 卡住也不能把返回键按住不放。
  Future<void> _stopPageMedia() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller
          .evaluateJavascript(source: _stopMediaScript)
          .timeout(const Duration(milliseconds: 250), onTimeout: () => null);
    } catch (_) {
      // WebView 可能已经没了；退出不为这个卡住。
    }
  }

  // ---------------------------------------------------------------------------
  // 鉴权与导航
  // ---------------------------------------------------------------------------

  /// 与 `epub_chapter_view.dart` 同一规则：只回答自己服务器的 Basic Auth
  /// 挑战，其他 host 一律 CANCEL，凭据不外泄。
  Future<HttpAuthResponse?> _onHttpAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  ) async {
    final serverHost = Uri.tryParse(_serverUrl)?.host ?? '';
    final user = SessionManager.basicAuthUser;
    if (serverHost.isEmpty ||
        user.isEmpty ||
        challenge.protectionSpace.host != serverHost) {
      return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
    }
    return HttpAuthResponse(
      username: user,
      password: SessionManager.basicAuthPassword,
      action: HttpAuthResponseAction.PROCEED,
    );
  }

  /// 只放行 `/picwords` 自己的页面。
  ///
  /// 插件页里有 `去复习面板`（/review/index）、`复习设置`（/review/settings）、
  /// `管理语言`（/language/index）这些站内链接。放行会把用户带进 Web 版页面，
  /// 与 App 自己的 Review / 设置重复，而且再想回来只能按返回。核过
  /// picwords.js：核心动线（开始 → 看图选词 → 反馈 → 继续 → 完成）全是
  /// `<button>`，这些链接都在 footer / 错误提示里，拦住不影响任何一次练习。
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    final target = _asUri(uri);
    final scheme = target.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return NavigationActionPolicy.CANCEL; // tel/mailto/intent：静默丢弃
    }

    final sameHost = target.host == (Uri.tryParse(_serverUrl)?.host ?? '');

    // 会话过期时页面会被 302 到 /login：就地提示重新登录，别让用户看一张
    // 在 App 里毫无意义的 Web 登录页。
    if (sameHost && _isLoginPath(target)) {
      _markLoginRequired();
      return NavigationActionPolicy.CANCEL;
    }
    if (sameHost && _isPicWordsPath(target)) {
      return NavigationActionPolicy.ALLOW;
    }

    _notifyBlocked(target);
    return NavigationActionPolicy.CANCEL;
  }

  bool _isPicWordsPath(Uri uri) {
    final prefix = '$_basePath/picwords';
    return uri.path == prefix || uri.path.startsWith('$prefix/');
  }

  /// 这个请求是不是「当前应该显示的那一页」（主框架 + /picwords 前缀）。
  bool _isOurPageRequest(WebResourceRequest request) {
    if (request.isForMainFrame != true) return false;
    return _isPicWordsPath(_asUri(request.url));
  }

  bool _isLoginPath(Uri uri) {
    final path = uri.path;
    return path == '/login' ||
        path.startsWith('/login?') ||
        path.startsWith('/login/');
  }

  void _notifyBlocked(Uri uri) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar(); // 连点多个链接不叠一堆
    messenger.showSnackBar(
      SnackBar(
        content: Text('Web-only link blocked: ${uri.path}'),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 注入脚本
// -----------------------------------------------------------------------------

/// `WebUri` 不是 `Uri` 的子类型，路径/host 判断统一转成 `Uri` 再做。
Uri _asUri(WebUri uri) => Uri.parse(uri.toString());

/// 页面配色：取自 App 的色板，与词卡 AI 页（`_serverAiTheme`）同一套取值。
typedef _PageTheme = ({
  String background,
  String surface,
  String primaryText,
  String secondaryText,
  String divider,
  String accent,
  bool dark,
});

_PageTheme _pageThemeOf(BuildContext context) {
  final scheme = context.appColorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (
    background: _cssColor(scheme.background.background),
    surface: _cssColor(scheme.background.surface),
    primaryText: _cssColor(scheme.text.primary),
    secondaryText: _cssColor(scheme.text.secondary),
    divider: _cssColor(scheme.border.dividerColor),
    // 深色下沿用 M3 深色主题的 primary：浅色主题的 primary 在深底上对比度
    // 不够，链接会糊成一片。
    accent: _cssColor(
      dark ? const Color(0xFFD0BCFF) : scheme.material3.primary,
    ),
    dark: dark,
  );
}

/// CSS 不接受 Flutter 的 0xAARRGGBB，这里只取 RGB（主题色都是不透明的）。
String _cssColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// 去 chrome + App 配色 + （墨水屏）去动画。
String _pageCss(_PageTheme theme, {required bool eInk}) {
  final eInkPart = eInk
      ? '''
/* 墨水屏：只关「会连续重绘」和「会脏」的东西，不动配色 ——
   --pw-accent/--pw-sage 是答对/答错的语义色，量化后仍然分得开。 */
.pw-app *, .pw-app *::before, .pw-app *::after {
  animation: none !important;
  transition: none !important;
  box-shadow: none !important;
}
.pw-spinner { display: none !important; }
/* 方角。picwords 里只有一部分圆角走 var(--pw-radius)，其余二十多处是写死的
   9/14/16/18/20/26px 和 50%/99px —— 单压变量压不干净（实测反馈卡仍是圆角），
   所以对整棵子树归零。 */
.pw-app, .pw-app *, .pw-app *::before, .pw-app *::after {
  border-radius: 0 !important;
}
.pw-app { --pw-radius: 0 !important; --pw-shadow: none !important; }
'''
      : '';

  return '''
/* 1. 去掉 Lute 全站导航：logo、h1 标题、Book/Term/Setting 菜单、
      语言选择/搜索/主题按钮、备份盘图标。 */
.menu-bar, .menu, #top-toolbar-placeholder,
#datatables_config_widget_top, #home_backup_icon {
  display: none !important;
}
html, body { margin: 0 !important; padding: 0 !important; }
/* .container 默认 margin: 0 24px；留白交给 .pw-app 自己的 padding。 */
.container {
  width: 100% !important;
  margin: 0 !important;
  padding: 0 !important;
  box-sizing: border-box;
}

/* 2. App 配色。picwords 的 --pw-* 都建立在下面这些 Song token 上。 */
body {
  --background-color: ${theme.background} !important;
  --font-color: ${theme.primaryText} !important;
  --panel-bg: ${theme.surface} !important;
  --text-muted: ${theme.secondaryText} !important;
  --border-subtle: ${theme.divider} !important;
  --border-strong: ${theme.divider} !important;
  --light-grey: ${theme.secondaryText} !important;
  --link-color: ${theme.accent} !important;
  --input-bg: ${theme.background} !important;
  --input-fg: ${theme.primaryText} !important;
  color-scheme: ${theme.dark ? 'dark' : 'light'} !important;
  background-color: ${theme.background} !important;
  color: ${theme.primaryText} !important;
}

/* 3. 一屏做完一道题。App 里这是全屏页，纵向空间就是屏幕高度；默认布局在
      手机（视口 363×695）上是「顶栏 56 + 标签 32 + 正方形图 323 + 句子 70 +
      选项 134 ≈ 690」，正好顶到边，答完出现反馈就溢出，每题都得往下拖。
      这里收紧纵向节奏、按视口高度给图片封顶，反馈出现时图片再让一档。 */
/* 与 AppBar 返回重复：页面内的「×」退出按钮去掉（退出即返回）。 */
#pw-exit { display: none !important; }
.pw-app { padding-top: 10px !important; padding-bottom: 14px !important; }
.pw-session-top { padding: 0 0 8px !important; }
.pw-label { margin: 0 0 8px !important; }

.pw-prompt-picture { gap: 10px !important; margin-bottom: 12px !important; }
.pw-prompt-picture .pw-art,
.pw-intro-card .pw-art {
  max-height: clamp(140px, 30vh, 300px) !important;
  /* 保持正方形并在列内居中：只压 max-height 会被 grid 拉成宽扁矩形。 */
  width: auto !important;
  justify-self: center !important;
}
.pw-cloze { line-height: 1.45 !important; }

.pw-options { gap: 8px !important; }
.pw-option { min-height: 54px !important; padding: 9px 12px !important; }

/* 出反馈后（对错 + 例句 + 继续）也要留在屏内。图片整张收掉：反馈卡自己带
   缩略图，答案也已经揭晓，这一屏的重点是「对不对 + 例句 + 继续」。 */
.pw-quiz:has(.pw-feedback) .pw-prompt-picture .pw-art {
  display: none !important;
}
.pw-quiz:has(.pw-feedback) .pw-prompt-picture {
  margin-bottom: 8px !important;
}
.pw-feedback { margin-top: 10px !important; padding: 12px !important; }

/* 反馈态把「题干 + 选项」一起压紧：它们此刻只是"刚才那张题"的回放，
   真正要看的是下面的对错、例句和继续。四种题型都要压（看图/释义/听音）。 */
.pw-quiz:has(.pw-feedback) .pw-prompt-word { padding: 6px 0 2px !important; }
.pw-quiz:has(.pw-feedback) .pw-prompt-word .pw-word {
  font-size: clamp(34px, 7vw, 56px) !important;
}
.pw-quiz:has(.pw-feedback) .pw-listen { padding: 4px 0 8px !important; gap: 6px !important; }
.pw-quiz:has(.pw-feedback) .pw-orb { width: 72px !important; height: 72px !important; }
.pw-quiz:has(.pw-feedback) .pw-options { gap: 6px !important; }
.pw-quiz:has(.pw-feedback) .pw-option {
  min-height: 42px !important;
  padding: 6px 10px !important;
}
.pw-quiz:has(.pw-feedback) .pw-options.is-words .pw-option-text {
  font-size: 18px !important;
}

/* 「继续」按钮里的箭头 SVG 在插件 ≤0.1.0 里没有尺寸规则（orb / icon-btn /
   speak 都有，只有按钮漏了）：窄屏按钮被 `flex: 1` 拉满后，图标长成满宽
   巨箭头，按钮被撑到约 200px 高，把自己顶出屏外。插件 0.1.1 已修
   （`.pw-btn svg { 16px }`），这条留着当旧版服务器的兜底 —— 连别人的
   Song 时插件可能还是 0.1.0。 */
.pw-btn svg {
  width: 16px !important;
  height: 16px !important;
  flex: 0 0 auto !important;
}

$eInkPart''';
}

/// 装载脚本的 JS。
///
/// 与 `eInkPaperScript` 同一套写法：取同 id 的 `<style>`、改 `textContent`、
/// 再 `appendChild` 一次 —— 已存在的节点会被"移动"到 head 末尾，于是我们的
/// 样式永远排在页面后加载的样式之后。
String _injectionScript(BuildContext context, {required bool eInk}) {
  final css = jsonEncode(_pageCss(_pageThemeOf(context), eInk: eInk));
  return '''
(function () {
  var id = 'lute-picwords-chrome';
  var s = document.getElementById(id);
  if (!s) { s = document.createElement('style'); s.id = id; }
  s.textContent = $css;
  (document.head || document.documentElement).appendChild(s);

  /* 插件用 new Audio(url) 放 /tts/ 的音频，那个对象不在 DOM 里，退出时
     querySelectorAll 抓不到。在它之前包一层构造函数，把实例登记下来。 */
  if (!window.__lutePwAudioPatched) {
    window.__lutePwAudioPatched = true;
    window.__lutePwAudios = [];
    var NativeAudio = window.Audio;
    if (NativeAudio) {
      window.Audio = function (src) {
        var a = new NativeAudio(src);
        window.__lutePwAudios.push(a);
        return a;
      };
      window.Audio.prototype = NativeAudio.prototype;
    }
  }

  /* 墨水屏：插件用 scrollTo({behavior:'smooth'})，一次 250–350ms 的补间在
     墨水屏上就是几十帧全屏刷新。只把 smooth 降级成 auto，位置原样保留。 */
  if (${eInk ? 'true' : 'false'} && !window.__lutePwScrollPatched) {
    window.__lutePwScrollPatched = true;
    var nativeScrollTo = window.scrollTo.bind(window);
    window.scrollTo = function (x, y) {
      if (typeof x === 'object' && x && x.behavior === 'smooth') {
        return nativeScrollTo({ left: x.left || 0, top: x.top || 0, behavior: 'auto' });
      }
      return nativeScrollTo(x, y);
    };
  }
})();
''';
}

const String _stopMediaScript = '''
(function () {
  try { window.speechSynthesis && window.speechSynthesis.cancel(); } catch (e) {}
  var live = window.__lutePwAudios || [];
  for (var i = 0; i < live.length; i++) {
    try { live[i].pause(); } catch (e) {}
  }
  var media = document.querySelectorAll('audio, video');
  for (var j = 0; j < media.length; j++) {
    try { media[j].pause(); } catch (e) {}
  }
})();
''';
