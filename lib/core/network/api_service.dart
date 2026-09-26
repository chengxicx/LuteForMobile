import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:song_mobile/core/services/backup_service.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';
import 'queued_dio_interceptor.dart';
import 'api_request_queue.dart';
import 'session_manager.dart';

class ApiService {
  final Dio _dio;
  static bool enableLogging = kDebugMode;
  static final ApiRequestQueue _requestQueue = ApiRequestQueue();
  static const String _defaultTermImageSearchParams =
      'q=[LUTE]&form=HDRSC2&first=1&tsc=ImageHoverTitle';

  ApiService({
    required String baseUrl,
    Dio? dio,
    String basicAuthUser = '',
    String basicAuthPassword = '',
  }) : _dio = _buildDio(
          dio,
          baseUrl: baseUrl,
          basicAuthUser: basicAuthUser,
          basicAuthPassword: basicAuthPassword,
        ) {
    _requestQueue.initialize(
      baseUrl,
      _dio,
      basicAuthUser: basicAuthUser,
      basicAuthPassword: basicAuthPassword,
    );
    _dio.interceptors.add(QueuedDioInterceptor(_requestQueue));
    _addSessionInterceptor();
    _addRetryInterceptor();
    _addLoggingInterceptor();
    _addStatusInterceptor();
  }

  static Dio _buildDio(
    Dio? dio, {
    required String baseUrl,
    required String basicAuthUser,
    required String basicAuthPassword,
  }) {
    final existing = dio ?? Dio();
    final options = existing.options;
    options.baseUrl = baseUrl;
    options.connectTimeout = const Duration(seconds: 10);
    options.receiveTimeout = const Duration(seconds: 10);
    options.sendTimeout = const Duration(seconds: 10);
    options.followRedirects = false;
    options.validateStatus = (status) => status != null && status < 400;
    options.headers['Content-Type'] = 'text/html';
    if (basicAuthUser.isNotEmpty) {
      final basicAuth = 'Basic ${base64Encode(utf8.encode('$basicAuthUser:$basicAuthPassword'))}';
      options.headers['Authorization'] = basicAuth;
    }
    return existing;
  }

  void _addStatusInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          ServerStatusManager.markSuccess();
          return handler.next(response);
        },
        onError: (error, handler) {
          if (error.error is ServerLoginRequiredException) {
            // Server answered; the session just needs a re-login.
            return handler.next(error);
          }
          ServerStatusManager.markError();
          return handler.next(error);
        },
      ),
    );
  }

  /// Attaches the multi-user session cookie and Basic Auth headers to every
  /// request, and handles 3xx responses (the Dio client runs with
  /// followRedirects=false): a redirect to /login means the lute multi-user
  /// session is missing or expired.
  void _addSessionInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final authHeaders = SessionManager.authHeaders();
          if (authHeaders.isEmpty) {
            options.headers.remove('Authorization');
            options.headers.remove('Cookie');
          } else {
            options.headers.addAll(authHeaders);
          }
          return handler.next(options);
        },
        onResponse: (response, handler) async {
          final statusCode = response.statusCode ?? 0;
          if (statusCode < 300 || statusCode >= 400) {
            return handler.next(response);
          }
          final location =
              response.headers.value('location') ?? '';
          if (_isLoginRedirect(location)) {
            await _handleLoginRedirect(response, handler);
            return;
          }
          if (response.requestOptions.method == 'GET' &&
              location.isNotEmpty &&
              (response.requestOptions.extra['redirectHops'] ?? 0) < 3) {
            try {
              final followed = await _followGetRedirect(
                response.requestOptions,
                location,
              );
              return handler.resolve(followed);
            } catch (e) {
              return handler.reject(
                DioException(
                  requestOptions: response.requestOptions,
                  error: e,
                  type: DioExceptionType.badResponse,
                ),
              );
            }
          }
          return handler.next(response);
        },
      ),
    );
  }

  bool _isLoginRedirect(String location) {
    if (location.isEmpty) return false;
    final path = location.startsWith('http')
        ? Uri.tryParse(location)?.path ?? location
        : location;
    return path == '/login' || path.startsWith('/login?') || path.startsWith('/login/');
  }

  Future<void> _handleLoginRedirect(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final requestOptions = response.requestOptions;
    if (requestOptions.extra['reloginRetry'] != true) {
      final recovered = await SessionManager.tryAutoRelogin();
      if (recovered) {
        try {
          final retryOptions = requestOptions.copyWith();
          retryOptions.extra['reloginRetry'] = true;
          retryOptions.headers.addAll(SessionManager.authHeaders());
          final retryResponse = await _dio.fetch(retryOptions);
          return handler.resolve(retryResponse);
        } catch (_) {
          // Fall through to the login-required error below.
        }
      }
    }
    SessionManager.markLoginRequired();
    return handler.reject(
      DioException(
        requestOptions: requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: const ServerLoginRequiredException(),
      ),
    );
  }

  Future<Response<dynamic>> _followGetRedirect(
    RequestOptions original,
    String location,
  ) {
    final nextUri = original.uri.resolve(location);
    final options = original.copyWith(path: nextUri.toString());
    options.extra['redirectHops'] =
        ((original.extra['redirectHops'] ?? 0) as int) + 1;
    options.headers.addAll(SessionManager.authHeaders());
    return _dio.fetch(options);
  }

  void _addRetryInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (_shouldRetry(error)) {
            final retryCount = error.requestOptions.extra['retryCount'] ?? 0;
            if (retryCount < 1) {
              error.requestOptions.extra['retryCount'] = retryCount + 1;
              await Future.delayed(Duration(milliseconds: 200));
              try {
                final response = await _dio.fetch(error.requestOptions);
                return handler.resolve(response);
              } catch (e) {
                return handler.next(error);
              }
            }
          }
          return handler.next(error);
        },
      ),
    );
  }

  void _addLoggingInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (enableLogging) {
            print('API REQUEST: ${options.method} ${options.uri}');
            if (options.data != null) {
              print('  Data: ${options.data}');
            }
          }
          return handler.next(options);
        },
        onResponse: (response, handler) {
          if (enableLogging) {
            print(
              'API RESPONSE: ${response.requestOptions.method} ${response.requestOptions.uri} - ${response.statusCode}',
            );
          }
          return handler.next(response);
        },
        onError: (error, handler) {
          if (enableLogging) {
            print(
              'API ERROR: ${error.requestOptions.method} ${error.requestOptions.uri} - ${error.type}',
            );
          }
          return handler.next(error);
        },
      ),
    );
  }

  bool _shouldRetry(DioException error) {
    if (error.requestOptions.extra['noRetry'] == true) {
      return false;
    }
    if (error.type == DioExceptionType.connectionError) {
      return true;
    }
    if (error.type == DioExceptionType.connectionTimeout) {
      return true;
    }
    if (error.type == DioExceptionType.sendTimeout) {
      return true;
    }
    if (error.type == DioExceptionType.unknown &&
        error.error?.toString().contains('errno=103') == true) {
      return true;
    }
    if (error.type == DioExceptionType.unknown &&
        error.error?.toString().contains('Connection reset') == true) {
      return true;
    }
    if (error.type == DioExceptionType.unknown &&
        error.error?.toString().contains('Software caused connection abort') ==
            true) {
      return true;
    }
    if (error.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    if (error.type == DioExceptionType.cancel) {
      return true;
    }
    return false;
  }

  bool get isConfigured => _dio.options.baseUrl.isNotEmpty;

  String get baseUrl => _dio.options.baseUrl;

  /// Loads a book page for active reading session.
  ///
  /// This method fetches the HTML content for a specific page and starts
  /// tracking the reading session by setting a start date. Use this when
  /// the user begins reading a new page or navigates to another page.
  ///
  /// Parameters:
  /// - [bookId]: The ID of the book to read from
  /// - [pageNum]: The page number to load
  ///
  /// Returns: HTML response containing the parsed page content with
  /// reading session tracking initialized
  ///
  /// See also:
  /// - [getBookPageStructure] - to get full HTML page with metadata
  /// - [peekBookPage] - to view a page without tracking
  /// - [refreshBookPage] - to reload current page without changing start date
  Future<Response<String>> loadBookPageForReading(
    int bookId,
    int pageNum,
  ) async {
    return await _dio.get<String>('/read/start_reading/$bookId/$pageNum');
  }

  Future<Response<String>> peekBookPage(int bookId, int pageNum) async {
    return await _dio.get<String>('/read/$bookId/peek/$pageNum');
  }

  Future<Response<String>> refreshBookPage(int bookId, int pageNum) async {
    return await _dio.get<String>('/read/refresh_page/$bookId/$pageNum');
  }

  Future<Response<String>> postPageDone(
    int bookId,
    int pageNum,
    bool restKnown,
  ) async {
    return await _dio.post<String>(
      '/read/page_done',
      data: {
        'bookid': bookId,
        'pagenum': pageNum,
        'restknown': restKnown ? 1 : 0,
      },
      options: Options(contentType: 'application/json'),
    );
  }

  Future<Response<String>> markPageRead(int bookId, int pageNum) async {
    return await postPageDone(bookId, pageNum, false);
  }

  Future<Response<String>> markPageKnown(int bookId, int pageNum) async {
    return await postPageDone(bookId, pageNum, true);
  }

  Future<Response<String>> getTermTooltip(int termId) async {
    final url = '/read/termpopup/$termId';
    return await _dio.get<String>(url);
  }

  Future<String> getRawTermTooltipHtml(int termId) async {
    final url = '/read/termpopup/$termId';
    final response = await _dio.get<String>(url);
    return response.data ?? '';
  }

  Future<Response<String>> getTermForm(int langId, String text) async {
    final encodedText = Uri.encodeComponent(text);
    return await _dio.get<String>('/read/termform/$langId/$encodedText');
  }

  Future<Response<String>> getTermFormById(int termId) async {
    return await _dio.get<String>('/read/edit_term/$termId');
  }

  Future<Response<String>> postTermForm(
    int langId,
    String text,
    dynamic data,
  ) async {
    final encodedText = Uri.encodeComponent(text);
    return await _dio.post<String>(
      '/read/termform/$langId/$encodedText',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> editTerm(int termId, dynamic data) async {
    return await _dio.post<String>(
      '/read/edit_term/$termId',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> saveTermImageFromUrl(
    int langId,
    String text,
    String src,
  ) async {
    return await _dio.post<String>(
      '/bing/save',
      data: {'src': src, 'text': text, 'langid': langId.toString()},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> uploadTermImage(
    int langId,
    String text,
    String imagePath,
  ) async {
    final payload = FormData.fromMap({
      'text': text,
      'langid': langId.toString(),
      'manual_image_file': await MultipartFile.fromFile(
        imagePath,
        filename: _filenameFromPath(imagePath),
      ),
    });
    return await _dio.post<String>('/bing/manual_image_post', data: payload);
  }

  Future<Response<String>> searchTermImages(
    int langId,
    String text,
    String searchString,
  ) async {
    final encodedText = Uri.encodeComponent(text);
    final encodedSearch = Uri.encodeComponent(
      _normalizeTermImageSearchString(searchString),
    );
    return await _dio.get<String>(
      '/bing/search/$langId/$encodedText/$encodedSearch',
    );
  }

  Future<Response<String>> getTermImageSearchPage(
    int langId,
    String text,
    String searchString,
  ) async {
    final encodedText = Uri.encodeComponent(text);
    final encodedSearch = Uri.encodeComponent(
      _normalizeTermImageSearchString(searchString),
    );
    return await _dio.get<String>(
      '/bing/search_page/$langId/$encodedText/$encodedSearch',
    );
  }

  String _normalizeTermImageSearchString(String searchString) {
    final trimmed = searchString.trim();
    if (trimmed.isEmpty) {
      return _defaultTermImageSearchParams;
    }

    // The server expects a Bing query-string template, not the raw term.
    if (trimmed.contains('[LUTE]') ||
        trimmed.contains('###') ||
        trimmed.contains('q=')) {
      return trimmed;
    }

    return _defaultTermImageSearchParams;
  }

  Future<Response<String>> getRawPath(String path) async {
    return await _dio.get<String>(path);
  }

  /// 拉取未归档书籍（服务端 `/book/datatables/active`）。
  ///
  /// [tagFilter] 对应服务端的 `filtTag` 表单字段。服务端只要收到非空的
  /// `filtTag`（或搜索词），就会**关闭 tag 聚合**、返回扁平书单
  /// （见 lute/book/datatables.py 的 `use_series_aggregation`）。
  /// 这正是客户端读取某个 Book Set 成员书的入口。
  Future<Response<String>> getActiveBooks({
    int draw = 1,
    int start = 0,
    int length = 100,
    String? search,
    String? tagFilter,
  }) async {
    final data = {
      'draw': draw,
      'start': start,
      'length': length,
      'columns[0][data]': '0',
      'columns[0][name]': 'BkTitle',
      'columns[0][searchable]': 'true',
      'columns[0][orderable]': 'true',
      'columns[0][search][value]': '',
      'columns[0][search][regex]': 'false',
      'columns[1][data]': '1',
      'columns[1][name]': 'LgName',
      'columns[1][searchable]': 'true',
      'columns[1][orderable]': 'true',
      'columns[1][search][value]': '',
      'columns[1][search][regex]': 'false',
      'columns[2][data]': '2',
      'columns[2][name]': 'TagList',
      'columns[2][searchable]': 'true',
      'columns[2][orderable]': 'true',
      'columns[2][search][value]': '',
      'columns[2][search][regex]': 'false',
      'columns[3][data]': '3',
      'columns[3][name]': 'WordCount',
      'columns[3][searchable]': 'true',
      'columns[3][orderable]': 'true',
      'columns[3][search][value]': '',
      'columns[3][search][regex]': 'false',
      'columns[4][data]': '4',
      'columns[4][name]': 'UnknownPercent',
      'columns[4][searchable]': 'false',
      'columns[4][orderable]': 'true',
      'columns[4][search][value]': '',
      'columns[4][search][regex]': 'false',
      'columns[5][data]': '5',
      'columns[5][name]': 'LastOpenedDate',
      'columns[5][searchable]': 'false',
      'columns[5][orderable]': 'true',
      'columns[5][search][value]': '',
      'columns[5][search][regex]': 'false',
      'columns[6][data]': '6',
      'columns[6][name]': 'DistinctCount',
      'columns[6][searchable]': 'false',
      'columns[6][orderable]': 'true',
      'columns[6][search][value]': '',
      'columns[6][search][regex]': 'false',
      'columns[7][data]': '7',
      'columns[7][name]': 'StatusDistribution',
      'columns[7][searchable]': 'false',
      'columns[7][orderable]': 'false',
      'columns[7][search][value]': '',
      'columns[7][search][regex]': 'false',
      'search[value]': search ?? '',
      'search[regex]': 'false',
      if (tagFilter != null && tagFilter.isNotEmpty) 'filtTag': tagFilter,
    };

    final response = await _dio.post<String>(
      '/book/datatables/active',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return response;
  }

  /// 拉取已归档书籍（服务端 `/book/datatables/Archived`）。
  /// [tagFilter] 语义同 [getActiveBooks]。
  Future<Response<String>> getArchivedBooks({
    int draw = 1,
    int start = 0,
    int length = 100,
    String? search,
    String? tagFilter,
  }) async {
    final data = {
      'draw': draw,
      'start': start,
      'length': length,
      'columns[0][data]': '0',
      'columns[0][name]': 'BkTitle',
      'columns[0][searchable]': 'true',
      'columns[0][orderable]': 'true',
      'columns[0][search][value]': '',
      'columns[0][search][regex]': 'false',
      'columns[1][data]': '1',
      'columns[1][name]': 'LgName',
      'columns[1][searchable]': 'true',
      'columns[1][orderable]': 'true',
      'columns[1][search][value]': '',
      'columns[1][search][regex]': 'false',
      'columns[2][data]': '2',
      'columns[2][name]': 'TagList',
      'columns[2][searchable]': 'true',
      'columns[2][orderable]': 'true',
      'columns[2][search][value]': '',
      'columns[2][search][regex]': 'false',
      'columns[3][data]': '3',
      'columns[3][name]': 'WordCount',
      'columns[3][searchable]': 'true',
      'columns[3][orderable]': 'true',
      'columns[3][search][value]': '',
      'columns[3][search][regex]': 'false',
      'columns[4][data]': '4',
      'columns[4][name]': 'UnknownPercent',
      'columns[4][searchable]': 'false',
      'columns[4][orderable]': 'true',
      'columns[4][search][value]': '',
      'columns[4][search][regex]': 'false',
      'columns[5][data]': '5',
      'columns[5][name]': 'LastOpenedDate',
      'columns[5][searchable]': 'false',
      'columns[5][orderable]': 'true',
      'columns[5][search][value]': '',
      'columns[5][search][regex]': 'false',
      'columns[6][data]': '6',
      'columns[6][name]': 'DistinctCount',
      'columns[6][searchable]': 'false',
      'columns[6][orderable]': 'true',
      'columns[6][search][value]': '',
      'columns[6][search][regex]': 'false',
      'columns[7][data]': '7',
      'columns[7][name]': 'StatusDistribution',
      'columns[7][searchable]': 'false',
      'columns[7][orderable]': 'false',
      'columns[7][search][value]': '',
      'columns[7][search][regex]': 'false',
      'search[value]': search ?? '',
      'search[regex]': 'false',
      if (tagFilter != null && tagFilter.isNotEmpty) 'filtTag': tagFilter,
    };

    final response = await _dio.post<String>(
      // Server registers this route with a capital 'A' (see lute/book/routes.py);
      // the lowercase route 404s and makes the archived toggle fail.
      '/book/datatables/Archived',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return response;
  }

  Future<Response<String>> getBookStats(
    int bookId, {
    Duration? timeout,
    bool forceRecalc = false,
    bool fullBook = false,
  }) async {
    final queryParameters = <String, dynamic>{};
    if (forceRecalc) {
      queryParameters['force_recalc'] = 'true';
    }
    if (fullBook) {
      queryParameters['full_book'] = 'true';
    }

    return await _dio.get<String>(
      '/book/table_stats/$bookId',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      options: Options(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        extra: {'noRetry': true},
      ),
    );
  }

  /// Gets full HTML page structure for a book page.
  ///
  /// This method fetches the complete HTML page including metadata
  /// like title, page count, audio settings, and navigation elements.
  /// The text content placeholder (`<div id="thetext">`) will be empty.
  ///
  /// Use this to extract metadata (title, page count, audio info).
  /// Use [loadBookPageForReading] to get actual parsed text content.
  ///
  /// Parameters:
  /// - [bookId]: The ID of the book
  /// - [pageNum]: The page number (or leave out to get current page)
  ///
  /// Returns: Full HTML page structure with metadata elements
  ///
  /// See also:
  /// - [loadBookPageForReading] - to get actual page text content
  Future<Response<String>> getBookPageStructure(
    int bookId, [
    int? pageNum,
  ]) async {
    final path = pageNum != null
        ? '/read/$bookId/page/$pageNum'
        : '/read/$bookId';
    return await _dio.get<String>(path);
  }

  Future<Response<String>> searchTerms(String text, int langId) async {
    final encodedText = Uri.encodeComponent(text);
    return await _dio.get<String>('/term/search/$encodedText/$langId');
  }

  Future<Response<String>> createTerm(int langId, String term) async {
    final encodedTerm = Uri.encodeComponent(term);
    return await _dio.post<String>(
      '/read/termform/$langId/$encodedTerm',
      data: {'text': term},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> getLanguageSettings(int langId) async {
    return await _dio.get<String>('/language/edit/$langId');
  }

  Future<Response<String>> postLanguageSettings(
    int langId,
    dynamic data,
  ) async {
    return await _dio.post<String>(
      '/language/edit/$langId',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> getLanguages() async {
    return await _dio.get<String>('/language/index');
  }

  Future<Response<String>> getNewLanguageSettings({
    String? templateName,
  }) async {
    if (templateName != null && templateName.trim().isNotEmpty) {
      final encodedTemplate = Uri.encodeComponent(templateName.trim());
      return await _dio.get<String>('/language/new/$encodedTemplate');
    }
    return await _dio.get<String>('/language/new');
  }

  Future<Response<String>> postNewLanguageSettings(
    dynamic data, {
    String? templateName,
  }) async {
    final path = (templateName != null && templateName.trim().isNotEmpty)
        ? '/language/new/${Uri.encodeComponent(templateName.trim())}'
        : '/language/new';
    return await _dio.post<String>(
      path,
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> loadPredefinedLanguage(String languageName) async {
    final encodedName = Uri.encodeComponent(languageName.trim());
    return await _dio.get<String>('/language/load_predefined/$encodedName');
  }

  Future<Response<String>> deleteLanguage(int langId) async {
    return await _dio.post<String>('/language/delete/$langId');
  }

  Future<Response<String>> getBookNew({String? importUrl}) async {
    if (importUrl != null && importUrl.trim().isNotEmpty) {
      return await _dio.get<String>(
        '/book/new',
        queryParameters: {'importurl': importUrl.trim()},
      );
    }
    return await _dio.get<String>('/book/new');
  }

  Future<Response<String>> createBook(dynamic data) async {
    if (data is FormData) {
      return await _dio.post<String>('/book/new', data: data);
    }

    return await _dio.post<String>(
      '/book/new',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<void> invalidateAllBookStatsCache({Duration? timeout}) async {
    await _dio.get<String>(
      '/refresh_all_stats',
      options: Options(receiveTimeout: timeout, sendTimeout: timeout),
    );
  }

  Future<Response<String>> getSettingsPage() async {
    return await _dio.get<String>('/settings/index');
  }

  Future<Response<String>> setUserSetting(String key, String value) async {
    return await _dio.post<String>('/settings/set/$key/$value');
  }

  Future<Response<String>> archiveBook(int bookId) async {
    return await _dio.post<String>('/book/archive/$bookId');
  }

  Future<Response<String>> unarchiveBook(int bookId) async {
    return await _dio.post<String>('/book/unarchive/$bookId');
  }

  Future<Response<String>> deleteBook(int bookId) async {
    return await _dio.post<String>('/book/delete/$bookId');
  }

  Future<Response<String>> getBookEdit(int bookId) async {
    return await _dio.get<String>('/book/edit/$bookId');
  }

  Future<Response<String>> postBookEdit(int bookId, dynamic data) async {
    if (data is FormData) {
      return await _dio.post<String>('/book/edit/$bookId', data: data);
    }
    return await _dio.post<String>(
      '/book/edit/$bookId',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  /// Posts the audio player's position (and, when known, its bookmarks).
  ///
  /// Goes to `/read/save_youtube_player_data` -- the **unified** media
  /// player's endpoint.  Its docstring says the shared media engine posts
  /// there "for every backend it drives, audio included", and the reader page
  /// renders the resume point as
  /// `LUTE_YT_DATA.startPos = video_current_pos or audio_current_pos`
  /// (`lute/read/routes.py`).  Writing the legacy `audio_current_pos` instead
  /// left the app's progress shadowed by whatever `video_current_pos` held
  /// from a previous browser session -- 17 of 21 audio books on the live
  /// server, with two visibly parked on the wrong spot.
  ///
  /// [bookmarks] is null when this session never loaded them.  The key is then
  /// **omitted**, not sent empty: the server only writes the column when the
  /// key is present, so "we don't know" cannot clear a stored list.
  Future<Response<String>> postUnifiedPlayerData(
    int bookId,
    double position, [
    List<double>? bookmarks,
  ]) async {
    return await _dio.post<String>(
      '/read/save_youtube_player_data',
      data: {
        'bookid': bookId,
        'position': position,
        if (bookmarks != null)
          'bookmarks': bookmarks.map((b) => b.toString()).join(';'),
      },
      options: Options(contentType: 'application/json'),
    );
  }

  /// Saves the current YouTube video position (mirrors the web player,
  /// which posts to `/read/save_youtube_player_data` on a timer).
  Future<Response<String>> postYoutubePlayerData(
    int bookId,
    double position,
  ) async {
    return await _dio.post<String>(
      '/read/save_youtube_player_data',
      data: {'bookid': bookId, 'position': position},
      options: Options(contentType: 'application/json'),
    );
  }

  // -------------------------------------------------------------------------
  // Review queue (mirrors lute.review.routes; the web UI posts the same JSON)
  // -------------------------------------------------------------------------

  /// POST /review/start -- builds the whole session in one call.
  ///
  /// Throws [DioException] with a 400 whose body carries `{"error": ...,
  /// "needs_fsrs": true}` when the server's fsrs package is missing.
  Future<dynamic> startReviewSession() async {
    final response = await _dio.post<dynamic>(
      '/review/start',
      data: '{}',
      options: Options(contentType: 'application/json'),
    );
    return response.data;
  }

  /// POST /review/grade -- grade one card; [rating] is 1 (Again) to 4 (Easy).
  ///
  /// [typed] checks a cloze/recall typed answer server-side; a wrong answer
  /// is forced to rating 1 and reported via the result's `correct`.
  Future<dynamic> gradeReviewCard(int cardId, int rating, {String? typed}) async {
    final response = await _dio.post<dynamic>(
      '/review/grade',
      data: {'card_id': cardId, 'rating': rating, 'typed': typed},
      options: Options(contentType: 'application/json'),
    );
    return response.data;
  }

  /// POST /review/undo -- reverse the most recent grading.
  Future<dynamic> undoReviewGrade() async {
    final response = await _dio.post<dynamic>(
      '/review/undo',
      data: '{}',
      options: Options(contentType: 'application/json'),
    );
    return response.data;
  }

  /// POST /review/scheduler/install -- one-click install of the fsrs package.
  Future<dynamic> installReviewScheduler() async {
    final response = await _dio.post<dynamic>(
      '/review/scheduler/install',
      data: '{}',
      options: Options(contentType: 'application/json'),
    );
    return response.data;
  }

  String _filenameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (segments.isEmpty) return path;
    return segments.last;
  }

  Future<Response<String>> getTermsDatatables({
    required int draw,
    required int start,
    required int length,
    String? search,
    int? langId,
    int? status,
    Set<String>? selectedStatuses,
  }) async {
    final data = {
      'draw': draw,
      'start': start,
      'length': length,
      'columns[0][data]': '0',
      'columns[0][name]': 'WoText',
      'columns[0][searchable]': 'true',
      'columns[0][orderable]': 'true',
      'columns[0][search][value]': '',
      'columns[0][search][regex]': 'false',
      'columns[1][data]': '1',
      'columns[1][name]': 'WoTranslation',
      'columns[1][searchable]': 'true',
      'columns[1][orderable]': 'true',
      'columns[2][data]': '2',
      'columns[2][name]': 'StID',
      'columns[2][searchable]': 'true',
      'columns[2][orderable]': 'true',
      'search[value]': search ?? '',
      'search[regex]': 'false',
      'filtAgeMin': '0',
      'filtAgeMax': '',
      'filtStatusMin': '0',
      'filtStatusMax': '99',
      'filtLanguage': langId?.toString() ?? '0',
      'filtText': search ?? '',
      'filtTermIDs': '',
      'parentags': '',
      'included_parentags': '',
      'excluded_parentags': '',
    };

    if (selectedStatuses != null && selectedStatuses.isNotEmpty) {
      final statusInts = selectedStatuses
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toList();

      if (statusInts.isNotEmpty) {
        data['filtStatusMin'] = statusInts
            .reduce((a, b) => a < b ? a : b)
            .toString();
        data['filtStatusMax'] = statusInts
            .reduce((a, b) => a > b ? a : b)
            .toString();
      }

      if (statusInts.contains(98)) {
        data['filtIncludeIgnored'] = 'true';
      }
    }

    return await _dio.post<String>(
      '/term/datatables',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<Response<String>> deleteTerm(int termId) async {
    return await _dio.post<String>('/term/delete/$termId');
  }

  Future<Response<String>> getTermCounts({
    required int? langId,
    int? statusMin,
    int? statusMax,
    String? search,
    int? ageMin,
    int? ageMax,
    Duration? timeout,
  }) async {
    final data = {
      'draw': 1,
      'start': 0,
      'length': 0,
      'columns[0][data]': '0',
      'columns[0][name]': 'WoText',
      'columns[0][searchable]': 'true',
      'columns[0][orderable]': 'true',
      'columns[1][data]': '1',
      'columns[1][name]': 'WoTranslation',
      'columns[1][searchable]': 'true',
      'columns[1][orderable]': 'true',
      'columns[2][data]': '2',
      'columns[2][name]': 'StID',
      'columns[2][searchable]': 'true',
      'columns[2][orderable]': 'true',
      'search[value]': search ?? '',
      'search[regex]': 'false',
      'filtAgeMin': (ageMin ?? 0).toString(),
      'filtAgeMax': ageMax?.toString() ?? '',
      'filtStatusMin': (statusMin ?? 0).toString(),
      'filtStatusMax': (statusMax ?? 99).toString(),
      'filtLanguage': langId?.toString() ?? '0',
      'filtText': search ?? '',
      'filtTermIDs': '',
      'parentags': '',
      'included_parentags': '',
      'excluded_parentags': '',
    };

    return await _dio.post<String>(
      '/term/datatables',
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
  }

  Future<Response<String>> getStatsData() async {
    return await _dio.get('/stats/data');
  }

  /// Term-trend / heatmap / summary data behind the web stats page's term
  /// charts.  [period] is one of `today`, `7days`, `monthly`; [langId] null
  /// means "all active languages".
  Future<Response<String>> getTermStatsData({
    required String period,
    int? langId,
  }) async {
    return await _dio.get<String>(
      '/stats/term_data',
      queryParameters: {
        'period': period,
        if (langId != null) 'lang_id': langId.toString(),
      },
    );
  }

  /// One vocabulary-progress report (`jlpt`, `cefr`, `topik`, `dele`,
  /// `russian`, `german`, `thai`, `french`, `arabic`, `hsk2`, `hsk3`).
  Future<Response<String>> getLevelReportData({
    required String kind,
    required int langId,
  }) async {
    return await _dio.get<String>(
      '/stats/${kind}_data',
      queryParameters: {'lang_id': langId.toString()},
    );
  }

  /// Grammar points detected on a reading page.  [text] is the page text the
  /// reader is showing; the server analyses the whole page when it is empty.
  Future<Response<String>> getGrammarAnalysis({
    required int bookId,
    required int pageNum,
    String? text,
  }) async {
    return await _dio.get<String>(
      '/read/grammar_analysis/$bookId/$pageNum',
      queryParameters: {
        if (text != null && text.trim().isNotEmpty) 'text': text,
      },
    );
  }

  Future<Response<String>> fetchAllTerms({
    int start = 0,
    int length = 1000,
    String? search,
    int? langId,
  }) async {
    final data = {
      'draw': 1,
      'start': start,
      'length': length,
      'columns[0][data]': '0',
      'columns[0][name]': 'WoText',
      'columns[0][searchable]': 'true',
      'columns[0][orderable]': 'true',
      'columns[0][search][value]': '',
      'columns[0][search][regex]': 'false',
      'columns[1][data]': '1',
      'columns[1][name]': 'WoTranslation',
      'columns[1][searchable]': 'true',
      'columns[1][orderable]': 'true',
      'columns[2][data]': '2',
      'columns[2][name]': 'StID',
      'columns[2][searchable]': 'true',
      'columns[2][orderable]': 'true',
      'search[value]': search ?? '',
      'search[regex]': 'false',
      'filtAgeMin': '0',
      'filtAgeMax': '',
      'filtStatusMin': '0',
      'filtStatusMax': '99',
      'filtLanguage': langId?.toString() ?? '0',
      'filtText': search ?? '',
      'filtTermIDs': '',
      'parentags': '',
      'included_parentags': '',
      'excluded_parentags': '',
    };

    return await _dio.post<String>(
      '/term/datatables',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  Future<void> triggerAutoBackup() async {
    try {
      if (enableLogging) {
        debugPrint('AUTO BACKUP: checking settings from $baseUrl');
      }
      final settings = await BackupService.getAllSettings(baseUrl);
      final backupAuto = settings['backup_auto'];
      final lastBackup = settings['lastbackup'];
      final shouldTrigger = shouldTriggerAutoBackup(settings, DateTime.now());

      if (enableLogging) {
        debugPrint(
          'AUTO BACKUP: backup_auto=$backupAuto, lastbackup=$lastBackup, shouldTrigger=$shouldTrigger',
        );
      }

      if (shouldTrigger) {
        if (enableLogging) {
          debugPrint('AUTO BACKUP: triggering automatic backup request');
        }
        await _dio.post('/backup/do_backup', data: {'type': 'automatic'});
        if (enableLogging) {
          debugPrint('AUTO BACKUP: backup request completed');
        }
      } else {
        if (enableLogging) {
          debugPrint('AUTO BACKUP: skipped');
        }
      }
    } catch (e) {
      if (enableLogging) {
        debugPrint('AUTO BACKUP: failed with error: $e');
      }
      // Silently fail on backup errors - don't block app launch
    }
  }

  @visibleForTesting
  static bool shouldTriggerAutoBackup(
    Map<String, dynamic> settings,
    DateTime now,
  ) {
    if (!_settingIsEnabled(settings['backup_auto'])) {
      return false;
    }

    final lastBackupTimestamp = _parseUnixTimestamp(settings['lastbackup']);
    if (lastBackupTimestamp == null) {
      return true;
    }

    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    final twentyFourHoursAgo = nowSeconds - (24 * 60 * 60);
    return lastBackupTimestamp < twentyFourHoursAgo;
  }

  static bool _settingIsEnabled(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == '1' ||
          normalized == 'true' ||
          normalized == 'y' ||
          normalized == 'yes' ||
          normalized == 'on';
    }
    return false;
  }

  static int? _parseUnixTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return int.tryParse(trimmed);
    }
    return null;
  }
}
