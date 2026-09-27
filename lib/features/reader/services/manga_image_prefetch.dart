import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logger/api_logger.dart';

/// Prefetches manga page images into the shared disk cache.
///
/// A manga page turn costs two loads: the page HTML (OCR word blocks) and
/// the page image itself.  The HTML has the Hive page cache, but the image
/// used to load straight off the network with only Flutter's small
/// in-memory ImageCache behind it, so every eviction (a few turns, or an
/// app restart) re-downloaded the same JPG.  This service downloads the
/// next page's image into the [DefaultCacheManager] disk cache -- the same
/// cache [CachedNetworkImage] reads from -- so by the time the reader
/// shows that page the bytes are already local.
class MangaImagePrefetch {
  /// URLs already handed to the cache manager (in flight or done), so
  /// flipping back and forth over a page does not re-download it.  A URL
  /// is removed again when its download failed, so a later visit retries.
  final Set<String> _requested = {};

  /// Downloads [url] into the disk cache.  No-op when the URL was already
  /// requested this session; failures are logged and swallowed -- the
  /// image simply loads from the network when the page is opened.
  Future<void> prefetch(String url, Map<String, String>? headers) async {
    if (url.isEmpty || !_requested.add(url)) return;
    try {
      await DefaultCacheManager().downloadFile(
        url,
        authHeaders: headers ?? const {},
      );
      ApiLogger.logCache('mangaImagePrefetch', details: 'DONE $url');
    } catch (e) {
      _requested.remove(url);
      ApiLogger.logError('mangaImagePrefetch', e, details: url);
    }
  }
}

final mangaImagePrefetchProvider = Provider<MangaImagePrefetch>((ref) {
  return MangaImagePrefetch();
});
