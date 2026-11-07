import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/models/language.dart';
import '../../../shared/providers/network_providers.dart';
import '../../../shared/theme/eink_paper.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../books/models/book_create.dart';
import '../../books/providers/books_provider.dart';
import '../../reader/providers/epub_offline_provider.dart';
import '../../reader/providers/sentence_tts_provider.dart';
import '../../reader/providers/tts_player_provider.dart';
import '../../reader/widgets/tts_player_widget.dart';
import '../../settings/models/tts_settings.dart';
import '../../settings/providers/settings_provider.dart';
import '../../settings/providers/tts_settings_provider.dart';
import '../../shadowing/models/shadowing_sentence.dart';
import '../../shadowing/providers/shadowing_provider.dart';
import '../../shadowing/widgets/shadowing_sheet.dart';
import '../providers/local_book_providers.dart';
import '../services/local_book_store.dart';
import '../services/local_chapter_speech.dart';
import '../services/local_epub_import.dart';
import '../services/local_epub_page.dart' show localEpubPageVersion;
import 'local_dict_lookup_sheet.dart';

/// Reader for a locally imported EPUB (Phase 2: no server, no terms).
///
/// The chapters are standalone pages generated at import and served by
/// the loopback server at `/local/<id>/<zip path>`; the page's own JS
/// handles selection / tap-to-word lookup (calling back into
/// [showLocalDictLookupSheet]) and reports scroll offsets, which are
/// persisted per chapter exactly like the server-book epub reader.
class LocalBookReaderScreen extends ConsumerStatefulWidget {
  const LocalBookReaderScreen({super.key, required this.bookId});

  final String bookId;

  @override
  ConsumerState<LocalBookReaderScreen> createState() =>
      _LocalBookReaderScreenState();
}

class _LocalBookReaderScreenState extends ConsumerState<LocalBookReaderScreen> {
  LocalBookRecord? _record;
  LocalEpubData? _data;
  int _chapter = 0;
  bool _loading = true;
  bool _pageReady = false;
  bool _night = false;
  int _fontPx = 18;

  InAppWebViewController? _controller;
  double _lastScrollTop = 0;
  Timer? _scrollFlushTimer;
  double? _pendingScrollRestore;
  Uri? _chapterUrl;

  /// Sentences of the current chapter, fed to the TTS player bar.
  ///
  /// Local chapters are plain extracted HTML without the server's token
  /// stream, so [extractLocalChapterSpeech] splits them on sentence
  /// punctuation (see that file for the trade-offs).
  List<TTSPlayerSentence> _ttsSentences = const [];
  List<ShadowingSentence> _shadowingSentences = const [];

  /// Language inferred from the chapter's `<html lang>`, already in the
  /// mapper's lowercase name form.
  String? _speechLanguageName;

  /// Server language id the shadowing endpoint scores against.  Resolved
  /// lazily on the first 跟读 tap (it needs the server's language list,
  /// and the book itself never stored one).
  int? _shadowingLanguageId;

  static const String _nightPrefsKey = 'local_epub_night';
  static const String _fontPrefsKey = 'local_epub_font';

  @override
  void initState() {
    super.initState();
    // 整本连续朗读（循环键第二档）读到本章最后一句时，播放器请这里
    // 翻到下一章；本地阅读器的「下一页」就是下一章。
    ref.read(ttsPlayerProvider.notifier).onRequestNextPage =
        _advanceChapterForContinuousReading;
    _load();
  }

  @override
  void dispose() {
    _scrollFlushTimer?.cancel();
    // 播放器持有的是 method 引用，不摘掉的话离开阅读页后仍在自动翻章。
    final ttsNotifier = ref.read(ttsPlayerProvider.notifier);
    if (ttsNotifier.onRequestNextPage == _advanceChapterForContinuousReading) {
      ttsNotifier.onRequestNextPage = null;
    }
    unawaited(ttsNotifier.stop());
    if (_lastScrollTop > 0) {
      final chapter = _chapter;
      final top = _lastScrollTop;
      unawaited(
        ref
            .read(localBookStoreProvider)
            .saveChapterScroll(widget.bookId, chapter, top),
      );
    }
    super.dispose();
  }

  Future<void> _load() async {
    final store = ref.read(localBookStoreProvider);
    var record = await store.get(widget.bookId);
    var data = await store.loadBookData(widget.bookId);

    // The extraction was built with the app's then-current page
    // template; a newer app rebuilds the chapter pages from the kept
    // original .epub so the lookup UI and fixes reach old books.
    if (record != null &&
        data != null &&
        record.pageVersion < localEpubPageVersion) {
      try {
        data = await ref
            .read(localEpubImporterProvider)
            .rebuildPages(data);
        await store.upsert(
          record.copyWith(pageVersion: localEpubPageVersion),
        );
        record = await store.get(widget.bookId);
        ApiLogger.logState(
          'localEpubRebuild',
          details: 'book ${widget.bookId} pages rebuilt',
        );
      } catch (e) {
        ApiLogger.logError('localEpubRebuild', e);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final night = prefs.getBool(_nightPrefsKey) ?? false;
    final font = prefs.getInt(_fontPrefsKey) ?? 18;

    if (!mounted) return;
    setState(() {
      _record = record;
      _data = data;
      _night = night;
      _fontPx = font;
      final last = record?.lastChapter ?? 0;
      _chapter = data == null || data.chapters.isEmpty
          ? 0
          : last.clamp(0, data.chapters.length - 1);
      _loading = false;
    });
    await _resolveChapterUrl();
    _pendingScrollRestore = await store.chapterScroll(
      widget.bookId,
      _chapter,
    );
    unawaited(_loadSpeechForChapter(_chapter));
  }

  /// Resolves the current chapter's local-server URL.  The server is
  /// started here (its baseUri is null until then -- reading it cold
  /// produced the infamous http://null/ page in the field).
  Future<void> _resolveChapterUrl() async {
    final data = _data;
    if (data == null || data.chapters.isEmpty) {
      _chapterUrl = null;
      return;
    }
    final segments = data.chapters[_chapter].path
        .split('/')
        .map(Uri.encodeComponent)
        .toList();
    final server = ref.read(epubLocalServerProvider);
    try {
      _chapterUrl = await server?.localBookFileUri(widget.bookId, segments);
    } catch (_) {
      _chapterUrl = null;
    }
  }

  /// Whether the read-aloud bar should be visible for the current chapter.
  ///
  /// Same gate as the server reader (`showAudioPlayer` + a configured TTS
  /// provider), plus "this chapter actually produced sentences".
  bool _showTtsPlayer() {
    if (!ref.read(settingsProvider).showAudioPlayer) return false;
    if (ref.read(ttsSettingsProvider).provider == TTSProvider.none) {
      return false;
    }
    return _ttsSentences.isNotEmpty;
  }

  /// Reads the chapter's extracted HTML and refreshes the player with its
  /// sentences.
  ///
  /// The page markup is already on disk (the importer wrote it), so this is
  /// a local file read, never a server round trip.
  Future<void> _loadSpeechForChapter(int index) async {
    final data = _data;
    if (data == null || index < 0 || index >= data.chapters.length) return;

    LocalChapterSpeech speech;
    try {
      final dir = await ref.read(localBookStoreProvider).bookDir(widget.bookId);
      final file = File(
        p.joinAll([dir, 'extract', ...data.chapters[index].path.split('/')]),
      );
      speech = extractLocalChapterSpeech(await file.readAsString());
    } catch (e) {
      ApiLogger.logError('localChapterSpeech', e, details: 'chapter=$index');
      speech = const LocalChapterSpeech(
        ttsSentences: [],
        shadowingSentences: [],
      );
    }
    // 读盘期间用户翻走了：这份结果属于旧章，丢掉。
    if (!mounted || _chapter != index) return;

    if (_speechLanguageName != speech.languageName) {
      _speechLanguageName = speech.languageName;
      // 换语言了，上一次解析出的跟读语言 id 不能再用。
      _shadowingLanguageId = null;
    }
    setState(() {
      _ttsSentences = speech.ttsSentences;
      _shadowingSentences = speech.shadowingSentences;
    });
    if (!_showTtsPlayer()) {
      unawaited(ref.read(ttsPlayerProvider.notifier).stop());
      return;
    }
    ref
        .read(ttsPlayerProvider.notifier)
        .loadPage(
          speech.ttsSentences,
          // 章节 `<html lang>` 推出的语言名；取不到时播放器用设置里的
          // 兜底语言码，并在播放条上说明。
          bookLanguageName: speech.languageName,
        );
  }

  /// Resolves the server language id shadowing scores against.
  ///
  /// Local imports never stored a language, so it is inferred from the
  /// chapter's `<html lang>` ([_speechLanguageName]) and matched against the
  /// server's language list.  Done lazily because only the shadowing panel
  /// needs it -- TTS itself works from the name alone.
  Future<int?> _resolveShadowingLanguageId() async {
    final cached = _shadowingLanguageId;
    if (cached != null) return cached;
    final name = _speechLanguageName;
    if (name == null || name.isEmpty) return null;
    try {
      final languages = await ref
          .read(contentServiceProvider)
          .getLanguagesWithIds();
      for (final language in languages) {
        if (language.name.toLowerCase().trim() == name) {
          _shadowingLanguageId = language.id;
          return language.id;
        }
      }
    } catch (e) {
      ApiLogger.logError('localShadowingLanguage', e, details: name);
    }
    return null;
  }

  /// Opens the shadowing panel on the sentence currently being read.
  Future<void> _openShadowing() async {
    final sentences = _shadowingSentences;
    if (sentences.isEmpty) return;

    final chapter = _chapter;
    final languageId = await _resolveShadowingLanguageId();
    if (!mounted || _chapter != chapter) return;

    // 评分必须是带语言 id 的句子；解析不到就维持 null，面板会明说
    // 「本页没有语言」，而不是拿错的语种乱打分。
    final scored = languageId == null
        ? sentences
        : [
            for (final sentence in sentences)
              ShadowingSentence(
                sentenceId: sentence.sentenceId,
                tokens: sentence.tokens,
                languageId: languageId,
                displayText: sentence.displayText,
              ),
          ];

    var initialIndex = 0;
    final playingId = ref.read(ttsPlayerProvider).currentSnippet?.sentenceId;
    if (playingId != null) {
      for (var i = 0; i < scored.length; i++) {
        if (scored[i].sentenceId == playingId) {
          initialIndex = i;
          break;
        }
      }
    }

    // 录音、回放、听原句共用出声通道，开面板前把正在念的停掉。
    unawaited(ref.read(ttsPlayerProvider.notifier).stop());
    unawaited(ref.read(sentenceTTSProvider.notifier).stop());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0x00000000),
      builder: (context) => ShadowingSheet(
        sentences: scored,
        initialIndex: initialIndex,
      ),
    ).then((_) {
      if (mounted) {
        unawaited(ref.read(shadowingProvider.notifier).reset());
      }
    });
  }

  /// Continuous read-aloud asked for "the next page": for a local book that
  /// is the next chapter.  Returns false at the end of the book so the
  /// player stops instead of looping.
  Future<bool> _advanceChapterForContinuousReading() async {
    final data = _data;
    if (data == null) return false;
    final next = _chapter + 1;
    if (next >= data.chapters.length) return false;
    await _goToChapter(next, loadSpeech: false);
    await _loadSpeechForChapter(next);
    return _ttsSentences.isNotEmpty;
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    // Kept here, not just in the tap callbacks: every _runJs (night /
    // font pushes, scroll restore) goes through this handle.  Losing
    // this assignment made the settings pushes silently skip forever.
    _controller = controller;
    _registerHandlers(controller);
  }

  void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'localEpubSelDebug',
      callback: (args) {
        ApiLogger.logState('localEpubSelDebug', details: '$args');
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'localEpubLookup',
      callback: (args) {
        ApiLogger.logRequest('localEpubLookup', details: '$args');
        if (args.isEmpty || args.first is! Map) return;
        final payload = (args.first as Map).cast<String, dynamic>();
        final text = payload['text']?.toString() ?? '';
        if (text.isEmpty || !mounted) return;
        showLocalDictLookupSheet(
          context,
          bookId: widget.bookId,
          term: text,
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'localEpubScroll',
      callback: (args) {
        final payload = args.isNotEmpty && args.first is Map
            ? (args.first as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final top = (payload['top'] as num?)?.toDouble() ?? 0;
        if (_pageReady) {
          _lastScrollTop = top;
          _scrollFlushTimer?.cancel();
          _scrollFlushTimer = Timer(const Duration(seconds: 1), _flushScroll);
        }
      },
    );
  }

  Future<void> _flushScroll() async {
    await ref
        .read(localBookStoreProvider)
        .saveChapterScroll(widget.bookId, _chapter, _lastScrollTop);
  }

  Future<void> _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    if (!mounted) return;
    setState(() => _pageReady = true);
    // Push the reader settings onto the freshly loaded page.
    await _pushSettings();
    final top = _pendingScrollRestore;
    _pendingScrollRestore = null;
    if (top != null && top > 0) {
      await _runJs('requestAnimationFrame(function(){window.scrollTo(0,$top);});');
    }
  }

  Future<void> _runJs(String source) async {
    final controller = _controller;
    if (controller == null || !_pageReady) {
      ApiLogger.logState(
        'localEpubRunJs',
        details: 'SKIP ready=$_pageReady controller=${controller != null}',
      );
      return;
    }
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      ApiLogger.logError('localEpubRunJs', e, details: source);
    }
  }

  Future<void> _pushSettings() async {
    // 先读 context，再 await：墨水屏标志不会在这一次推送里变，读早了只是
    // 为了让 analyze 的 use_build_context_synchronously 满意。深色主题
    // 代表"现在要夜里读"，此时不钉白纸。
    final paper =
        context.eInk &&
        Theme.of(context).brightness == Brightness.light &&
        !_night;
    await _runJs(
      'window.LuteLocalBridge && window.LuteLocalBridge.setNight($_night)',
    );
    await _runJs(
      'window.LuteLocalBridge && window.LuteLocalBridge.setFontSize($_fontPx)',
    );
    // 墨水屏纸张：白底 + 纯黑墨 + 浅彩状态。与 reader-mode EPUB 共用
    // `shared/theme/eink_paper.dart` 那一份 CSS —— 纸色不该因为书是本地
    // 导入的还是服务器来的而不同。夜间（_night）时撤销，交给页面反相。
    await _runJs(eInkPaperScript(enabled: paper));
  }

  Future<void> _toggleNight() async {
    setState(() => _night = !_night);
    final paper = context.eInk && !_night;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nightPrefsKey, _night);
    await _runJs(
      'window.LuteLocalBridge && window.LuteLocalBridge.setNight($_night)',
    );
    // 夜间/白纸两种纸张互斥，切完要重钉一次（见 _pushSettings）。
    await _runJs(eInkPaperScript(enabled: paper));
  }

  Future<void> _bumpFont(int delta) async {
    final next = (_fontPx + delta).clamp(12, 36);
    if (next == _fontPx) return;
    setState(() => _fontPx = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_fontPrefsKey, next);
    await _runJs(
      'window.LuteLocalBridge && window.LuteLocalBridge.setFontSize($next)',
    );
  }

  Future<void> _goToChapter(int index, {bool loadSpeech = true}) async {
    final data = _data;
    if (data == null || index < 0 || index >= data.chapters.length) return;
    // Flush the old chapter's position before switching.
    if (_lastScrollTop > 0) await _flushScroll();
    setState(() {
      _chapter = index;
      _pageReady = false;
      _lastScrollTop = 0;
    });
    await ref.read(localBookStoreProvider).setLastChapter(widget.bookId, index);
    await _resolveChapterUrl();
    _pendingScrollRestore = await ref
        .read(localBookStoreProvider)
        .chapterScroll(widget.bookId, index);
    final url = _chapterUrl;
    if (url != null) {
      await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
    }
    // 连续朗读的跨章路径自己等待这一份（见 _advanceChapterForContinuousReading）。
    if (loadSpeech) unawaited(_loadSpeechForChapter(index));
  }

  Future<void> _uploadToServer() async {
    final store = ref.read(localBookStoreProvider);
    final epubPath = await store.epubFilePath(widget.bookId);
    if (epubPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The original .epub file is missing.')),
        );
      }
      return;
    }
    final serverBookId = await showDialog<int>(
      context: context,
      builder: (_) => _UploadDialog(
        defaultTitle: _record?.title ?? _data?.title ?? '',
        epubPath: epubPath,
      ),
    );
    if (serverBookId == null) return;
    await store.setServerBookId(widget.bookId, serverBookId);
    if (!mounted) return;
    // The shelf learns about the new server book.
    unawaited(
      ref.read(booksProvider.notifier).loadBooks(forceRefresh: true),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Imported to the server. It now reads with full term '
          'features from the bookshelf.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    final record = _record;
    final title = record?.title ?? data?.title ?? 'Local book';
    final chapterCount = data?.chapters.length ?? 0;
    final showTtsPlayer =
        ref.watch(settingsProvider.select((s) => s.showAudioPlayer)) &&
        ref.watch(ttsSettingsProvider.select((s) => s.provider)) !=
            TTSProvider.none &&
        _ttsSentences.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.format_size),
            tooltip: 'Smaller text',
            onPressed: () => _bumpFont(-2),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            tooltip: 'Larger text',
            onPressed: () => _bumpFont(2),
          ),
          IconButton(
            icon: Icon(_night ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Night mode',
            onPressed: _toggleNight,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'upload') _uploadToServer();
            },
            itemBuilder: (_) => [
              if (record?.serverBookId == null)
                const PopupMenuItem(
                  value: 'upload',
                  child: ListTile(
                    leading: Icon(Icons.cloud_upload),
                    title: Text('Import to server'),
                    subtitle: Text('Upgrade to a full Lute book'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
            ],
          ),
        ],
      ),
      endDrawer: data == null
          ? null
          : Drawer(
              child: ListView.builder(
                itemCount: data.chapters.length,
                itemBuilder: (context, index) {
                  final chapter = data.chapters[index];
                  return ListTile(
                    selected: index == _chapter,
                    title: Text(
                      chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _goToChapter(index);
                    },
                  );
                },
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : data == null || chapterCount == 0
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This book is missing on disk. Delete and import it '
                  'again.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : Column(
              children: [
                // 朗读条与服务器阅读页同一套：句子来自本章 HTML，
                // 跟读入口在句子表非空时可用。
                if (showTtsPlayer)
                  TTSPlayerWidget(
                    onShadowing: _shadowingSentences.isEmpty
                        ? null
                        : _openShadowing,
                  ),
                Expanded(
                  child: _chapterUrl == null
                      ? Center(
                          child: Text(
                            'Could not start the local reader service. '
                            'Reopen the book.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        )
                      : InAppWebView(
                          key: ValueKey(
                            'local-epub-${widget.bookId}-$_chapter',
                          ),
                          initialUrlRequest: URLRequest(
                            url: WebUri(_chapterUrl.toString()),
                          ),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                            supportZoom: false,
                            transparentBackground: true,
                          ),
                          // Same reason as the server chapter view: a
                          // platform view with no recognizer caches every
                          // pointer event until the finger lifts, so a slow
                          // drag scrolls one line at most.  Nothing else in
                          // this screen competes for the gesture, so the
                          // WebView can claim it at touch-down.
                          gestureRecognizers:
                              <Factory<OneSequenceGestureRecognizer>>{
                                Factory<OneSequenceGestureRecognizer>(
                                  () => EagerGestureRecognizer(),
                                ),
                              },
                          onWebViewCreated: _onWebViewCreated,
                          onLoadStop: _onLoadStop,
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: _chapter > 0
                            ? () => _goToChapter(_chapter - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Prev'),
                      ),
                      Text('${_chapter + 1} / $chapterCount'),
                      TextButton.icon(
                        onPressed: _chapter + 1 < chapterCount
                            ? () => _goToChapter(_chapter + 1)
                            : null,
                        label: const Text('Next'),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Asks for language + title, then re-uploads the original .epub via
/// the standard book-creation flow.  Reading progress stays local; the
/// server book starts fresh like any new import.
class _UploadDialog extends ConsumerStatefulWidget {
  const _UploadDialog({required this.defaultTitle, required this.epubPath});

  final String defaultTitle;
  final String epubPath;

  @override
  ConsumerState<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends ConsumerState<_UploadDialog> {
  final _titleController = TextEditingController();
  List<Language> _languages = const [];
  int? _languageId;
  bool _loadingLanguages = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.defaultTitle;
    _loadLanguages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _loadLanguages() async {
    try {
      final languages = await ref
          .read(contentServiceProvider)
          .getLanguagesWithIds();
      if (!mounted) return;
      setState(() {
        _languages = languages;
        _languageId = languages.isNotEmpty ? languages.first.id : null;
        _loadingLanguages = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLanguages = false;
        _error = 'Could not reach the server: $e';
      });
    }
  }

  Future<void> _save() async {
    final languageId = _languageId;
    final title = _titleController.text.trim();
    if (languageId == null || title.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bookId = await ref
          .read(contentServiceProvider)
          .createBook(
            BookCreateRequest(
              languageId: languageId,
              title: title,
              text: '',
              textFilePath: widget.epubPath,
              // The form's "Type" defaults to plain text; an epub file
              // must import as a reader-mode book or the chapter pages
              // never materialize server-side.
              bookType: widget.epubPath.toLowerCase().endsWith('.epub')
                  ? 'epub'
                  : null,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop(bookId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import to server'),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width * 0.85,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 12),
            ],
            if (_loadingLanguages)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              DropdownButtonFormField<int>(
                initialValue: _languageId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Language'),
                items: _languages
                    .map(
                      (l) => DropdownMenuItem(value: l.id, child: Text(l.name)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _languageId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving || _languageId == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Upload'),
        ),
      ],
    );
  }
}
