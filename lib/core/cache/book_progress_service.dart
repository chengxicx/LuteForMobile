import 'package:hive_ce/hive.dart';
import 'cache_logger.dart';

/// 每本书「上次读到第几页」的本地记录。
///
/// 为什么需要它：`Settings.currentBookPage`（SharedPreferences）只在**当前
/// 打开的那本书**上有效 —— `updateCurrentBook` 一旦换书就会
/// `clearCurrentBookPage`，所以地铁里从书架切到昨天读过的另一本书时，
/// 页码已经丢了，只能回退到「向服务端问读到第几页」，而离线时问不到。
///
/// 刻意放在**系统可回收的 cache 目录**（与 `page_cache` 同一个 Hive 根），
/// 而不是 support/documents：OS 清缓存时页码记录和页缓存会一起消失，
/// 绝不会留下「记着页码、那一页却不在」的悬空状态 —— 那种状态下开书会
/// 命中一个必然失败的本地页码，反而不如退化成「无记录」走网络。
///
/// box 用原生 `Box<int>`（key = bookId 字符串），不需要 adapter，也不需要
/// 动 `hive_registrar.g.dart`。
class BookProgressService {
  static const String _boxName = 'book_progress';

  Box<int>? _box;
  bool _isInitialized = false;

  BookProgressService();

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      // 沿用全局的 Hive 根（main.dart 里 initFlutter 到 cache 目录），
      // 不在这里再 init 一次：hive_ce 的 init 是直接覆盖全局 homePath，
      // 多一个调用点就多一个「谁最后 init 谁说了算」的隐患。
      _box = await Hive.openBox<int>(_boxName);
      _isInitialized = true;
      CacheLogger.log('$_boxName initialized');
    } catch (e) {
      // 缓存不可用不该拖垮阅读：标记为已初始化，后续一律返回 null。
      CacheLogger.logError('initialize', e);
      _isInitialized = true;
    }
  }

  Future<Box<int>?> _getBox() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _box;
  }

  String _key(int bookId) => '$bookId';

  /// 读不到一律返回 null（含未初始化、box 打不开、key 不存在）。
  Future<int?> getPage(int bookId) async {
    try {
      final box = await _getBox();
      if (box == null) return null;

      final page = box.get(_key(bookId));
      if (page == null || page <= 0) {
        CacheLogger.logMiss(_boxName, bookId);
        return null;
      }

      CacheLogger.logHit(_boxName, bookId);
      return page;
    } catch (e) {
      CacheLogger.logError('getPage', e);
      return null;
    }
  }

  Future<void> savePage(int bookId, int page) async {
    if (page <= 0) return;
    try {
      final box = await _getBox();
      if (box == null) return;

      await box.put(_key(bookId), page);
      CacheLogger.logSave(_boxName, bookId);
    } catch (e) {
      CacheLogger.logError('savePage', e);
    }
  }

  Future<void> removeBook(int bookId) async {
    try {
      final box = await _getBox();
      if (box == null) return;

      await box.delete(_key(bookId));
      CacheLogger.log('$_boxName removed book $bookId');
    } catch (e) {
      CacheLogger.logError('removeBook', e);
    }
  }

  Future<void> clearAll() async {
    try {
      final box = await _getBox();
      if (box == null) return;

      await box.clear();
      CacheLogger.logClear(_boxName);
    } catch (e) {
      CacheLogger.logError('clearAll', e);
    }
  }

  Future<void> close() async {
    try {
      if (_box != null && _box!.isOpen) {
        await _box!.close();
      }
      _box = null;
      _isInitialized = false;
    } catch (e) {
      CacheLogger.logError('close', e);
    }
  }
}
