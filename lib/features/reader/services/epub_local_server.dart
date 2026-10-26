import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logger/api_logger.dart';
import 'epub_offline_html.dart';
import 'epub_offline_store.dart';

/// Serves the EPUB offline packs to the reader WebView.
///
/// A tiny loopback HTTP server that mirrors the server's URL space
/// (`/read/epub_render/<bookId>/<page>`, `/static/epub/...`,
/// `/static/css/styles.css`, `/theme/current`, ...).  The pages it
/// hands out are the same documents the server renders -- the
/// serve-time [rewriteEpubRenderHtml] re-applies the `look` / `furigana`
/// / `triple` query the server would have baked in -- so the WebView,
/// its JS bridge, tap handlers and scroll reporting work unchanged,
/// online server or local pack alike.
///
/// It also answers `POST /read/shadowing/readings` from the pack's
/// stored responses, which is what keeps furigana alive offline; a miss
/// returns 404 and the page's own fetch logic degrades silently.
///
/// Loopback cleartext is already permitted on Android
/// (`usesCleartextTraffic="true"`) and exempt from ATS on iOS; the
/// server binds 127.0.0.1 only and never runs on web builds.
class EpubLocalServer {
  EpubLocalServer({required this.store, this.localRootResolver});

  final EpubOfflineStore store;

  /// Resolves the on-disk root of the locally imported books (Phase 2);
  /// URL paths under `/local/<bookId>/<...>` are served from
  /// `<root>/<bookId>/extract/<...>`.  Null disables the route.
  final Future<String> Function()? localRootResolver;
  HttpServer? _server;

  static const Map<String, String> _contentTypes = {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'xhtml': 'text/html; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'js': 'application/javascript; charset=utf-8',
    'mjs': 'application/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'svg': 'image/svg+xml',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'eot': 'application/vnd.ms-fontobject',
    'mp3': 'audio/mpeg',
    'mp4': 'video/mp4',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
    'txt': 'text/plain; charset=utf-8',
  };

  /// Starts the server if needed and returns its base uri
  /// (`http://127.0.0.1:<port>`).
  Future<Uri> ensureStarted() async {
    final existing = _server;
    if (existing != null) return _baseUriOf(existing);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      (request) {
        _handle(request).catchError((Object e, StackTrace st) {
          ApiLogger.logError('epubLocalServer', e, details: '$st');
          _safeRespond(request, HttpStatus.internalServerError);
        });
      },
      onError: (Object e) => ApiLogger.logError('epubLocalServerListen', e),
      cancelOnError: false,
    );
    return _baseUriOf(server);
  }

  Uri _baseUriOf(HttpServer server) => Uri.parse('http://127.0.0.1:${server.port}');

  Uri? get baseUri {
    final server = _server;
    return server == null ? null : _baseUriOf(server);
  }

  /// Local URL for one chapter page, or null when the pack does not
  /// have it.  Starting the server is part of the deal: the caller is
  /// about to load this into the WebView.
  Future<Uri?> localPageUrl(
    int bookId,
    int pageNum, {
    String look = 'original',
    bool furigana = false,
    bool triple = false,
  }) async {
    if (!await store.hasPage(bookId, pageNum)) return null;
    final base = await ensureStarted();
    return base.replace(
      path: '/read/epub_render/$bookId/$pageNum',
      queryParameters: {
        'look': look,
        'furigana': furigana ? '1' : '0',
        'triple': triple ? '1' : '0',
      },
    );
  }

  /// URL for a locally imported book's file (`/local/<id>/<...>`), or
  /// null when the local-book route is unavailable.  Starts the server
  /// if needed -- callers must not read [baseUri] directly, it is null
  /// until then.
  Future<Uri?> localBookFileUri(String bookId, List<String> segments) async {
    if (localRootResolver == null) return null;
    final base = await ensureStarted();
    return base.replace(
      pathSegments: ['local', bookId, ...segments],
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void _safeRespond(HttpRequest request, int status) {
    try {
      request.response.statusCode = status;
      request.response.close();
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' &&
        request.uri.path == '/read/shadowing/readings') {
      await _handleReadings(request);
      return;
    }
    if (request.method == 'GET') {
      await _handleGet(request);
      return;
    }
    _safeRespond(request, HttpStatus.methodNotAllowed);
  }

  Future<void> _handleReadings(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        _safeRespond(request, HttpStatus.badRequest);
        return;
      }
      final langId = decoded['language_id'];
      final tokens = decoded['tokens'];
      if (langId is! num || tokens is! List) {
        _safeRespond(request, HttpStatus.badRequest);
        return;
      }
      final key = EpubOfflineStore.canonicalReadingsKey(
        langId.toInt(),
        tokens.map((t) => t.toString()).toList(),
      );
      final stored = await store.readReadings(key);
      if (stored == null) {
        _safeRespond(request, HttpStatus.notFound);
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.parse(
        'application/json; charset=utf-8',
      );
      request.response.headers.set('Cache-Control', 'no-cache');
      request.response.write(stored);
      await request.response.close();
    } on FormatException {
      _safeRespond(request, HttpStatus.badRequest);
    }
  }

  Future<void> _handleGet(HttpRequest request) async {
    final path = EpubOfflineStore.normalizeUrlPath(request.uri.path);
    if (path == null) {
      _safeRespond(request, HttpStatus.notFound);
      return;
    }

    final response = request.response;
    response.headers.set('Cache-Control', 'no-cache');

    // Locally imported books (Phase 2): /local/<bookId>/<zip path> is
    // served from <localRoot>/<bookId>/extract/<zip path>.  The
    // chapters were rewritten into standalone pages at import, so this
    // is plain static file serving.
    if (path.startsWith('local/')) {
      final resolver = localRootResolver;
      if (resolver == null) {
        _safeRespond(request, HttpStatus.notFound);
        return;
      }
      final segments = path.split('/');
      // local / <bookId> / <rest...>
      if (segments.length < 3) {
        _safeRespond(request, HttpStatus.notFound);
        return;
      }
      final rel = segments.sublist(2).join('/');
      final root = await resolver();
      final file = File(
        p.joinAll([root, segments[1], 'extract', ...rel.split('/')]),
      );
      if (!await file.exists()) {
        _safeRespond(request, HttpStatus.notFound);
        return;
      }
      final bytes = await file.readAsBytes();
      final dot = rel.lastIndexOf('.');
      final ext = dot >= 0 ? rel.substring(dot + 1).toLowerCase() : '';
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.parse(
        _contentTypes[ext] ?? 'application/octet-stream',
      );
      response.add(bytes);
      await response.close();
      return;
    }

    if (path.startsWith('read/epub_render/')) {
      final html = await store.readText(path);
      if (html == null) {
        _safeRespond(request, HttpStatus.notFound);
        return;
      }
      final query = request.uri.queryParameters;
      final rewritten = rewriteEpubRenderHtml(
        html,
        look: query['look'] ?? 'original',
        furigana: query['furigana'] == '1',
        triple: query['triple'] == '1',
      );
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.parse(
        'text/html; charset=utf-8',
      );
      response.write(rewritten);
      await response.close();
      return;
    }

    final bytes = await store.readBytes(path);
    if (bytes == null) {
      _safeRespond(request, HttpStatus.notFound);
      return;
    }
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.parse(
      _contentTypes[ext] ?? 'application/octet-stream',
    );
    response.add(bytes);
    await response.close();
  }
}
