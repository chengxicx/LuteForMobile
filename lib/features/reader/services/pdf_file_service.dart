import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/logger/api_logger.dart';
import '../../../core/network/session_manager.dart';

/// The server's session is gone (redirected to /login); the user must
/// sign in again before the download can succeed.
class PdfLoginRequiredException implements Exception {
  const PdfLoginRequiredException();
  @override
  String toString() => 'Server session expired. Please sign in again.';
}

/// Makes a book's PDF file available locally so pages can be rendered
/// offline-fast with a pdfium plugin.
///
/// The server exposes a PDF book's whole file under one `/static/...` URL
/// (the web reader hands it to pdf.js, which streams it).  For native
/// rendering the whole file is downloaded once -- with the session auth
/// headers, streaming to a `.part` temp file that is renamed into place --
/// and reused on every later open as long as the local size matches the
/// remote one (a cheap `Range: bytes=0-0` probe).  This mirrors how the
/// audio player caches audiobook files.
class PdfFileService {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // PDFs can be large; do not let a slow download die mid-file.
      receiveTimeout: const Duration(minutes: 15),
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
    ),
  );

  /// Returns the local path of [url]'s PDF for this book, downloading it
  /// first when the cached copy is missing or stale.  [onProgress]
  /// reports (received, totalBytes) during the download; totalBytes is -1
  /// when the server does not disclose the size.
  Future<String> ensureLocalPdf(
    int bookId,
    String url,
    Map<String, String> authHeaders, {
    void Function(int received, int total)? onProgress,
    bool retriedAfterLogin = false,
  }) async {
    final cacheDir = await getApplicationCacheDirectory();
    final pdfDir = Directory('${cacheDir.path}/pdfs');
    await pdfDir.create(recursive: true);
    final cacheFile = File(
      '${pdfDir.path}/pdf_${bookId}_${url.hashCode.abs()}.pdf',
    );

    final remoteSize = await _probeRemoteSize(url, authHeaders);
    if (remoteSize != null) {
      final localSize = await cacheFile.exists()
          ? await cacheFile.length()
          : -1;
      if (localSize == remoteSize) {
        return cacheFile.path;
      }
    }

    await _downloadToFile(
      url,
      authHeaders,
      cacheFile,
      onProgress,
      retriedAfterLogin,
    );
    return cacheFile.path;
  }

  /// The remote file size via a 1-byte range request, or null when the
  /// server does not support ranges / is unreachable.  Null never means
  /// "must re-download": the download then simply overwrites the file.
  Future<int?> _probeRemoteSize(
    String url,
    Map<String, String> authHeaders,
  ) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: {...authHeaders, 'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 206) {
        final contentRange = response.headers.value('content-range') ?? '';
        final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
        return match != null ? int.tryParse(match.group(1)!) : null;
      }
      if (status == 200) {
        final contentLength = response.headers.value('content-length');
        return contentLength != null ? int.tryParse(contentLength) : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _downloadToFile(
    String url,
    Map<String, String> authHeaders,
    File target,
    void Function(int received, int total)? onProgress,
    bool retriedAfterLogin,
  ) async {
    final tmp = File('${target.path}.part');
    IOSink? sink;
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: authHeaders,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        // Redirected (e.g. to /login): the multi-user session is gone.
        if (!retriedAfterLogin && await SessionManager.tryAutoRelogin()) {
          await _downloadToFile(
            url,
            SessionManager.authHeaders(),
            target,
            onProgress,
            true,
          );
          return;
        }
        throw const PdfLoginRequiredException();
      }
      final total =
          int.tryParse(response.headers.value('content-length') ?? '') ?? -1;
      var received = 0;
      sink = tmp.openWrite();
      await sink.addStream(
        response.data!.stream.map((chunk) {
          received += chunk.length;
          onProgress?.call(received, total);
          return chunk;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      await tmp.rename(target.path);
      ApiLogger.logCache(
        'pdfFileDownload',
        details: 'bookId file=${target.path}, bytes=$received',
      );
    } catch (e) {
      try {
        sink ??= tmp.openWrite();
        await sink.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      ApiLogger.logError('pdfFileDownload', e);
      rethrow;
    }
  }
}

final pdfFileServiceProvider = Provider<PdfFileService>((ref) {
  return PdfFileService();
});
