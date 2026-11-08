import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import 'manga_image_cache.dart';

/// 把漫画页图预热进自管缓存（[MangaImageCache]）。
///
/// 阅读页的预取窗口是当前页 ±3：窗口重叠，翻一页只会真正新增一页的
/// HTML 与图片，其余都是本地命中。显式下载（pin）的书里这些图不会被
/// 全局配额淘汰。
class MangaImagePrefetch {
  MangaImagePrefetch(this._cache);

  final MangaImageCache _cache;

  /// 确保 [imagePath] 已在磁盘上；失败只记日志，交给页面回退到网络。
  Future<void> prefetch({required int bookId, required String imagePath}) async {
    if (imagePath.isEmpty) return;
    try {
      await _cache.ensure(bookId, imagePath);
    } catch (e) {
      ApiLogger.logError('mangaImagePrefetch', e, details: imagePath);
    }
  }
}

final mangaImagePrefetchProvider = Provider<MangaImagePrefetch>((ref) {
  return MangaImagePrefetch(ref.watch(mangaImageCacheProvider));
});
