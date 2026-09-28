import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/providers/books_provider.dart';
import 'package:song_mobile/features/reader/providers/sentence_tts_provider.dart';

/// 「错误提示一旦写上就再也清不掉」的回归测试。
///
/// 背景（Leaf5C 实测）：断网打开书架 → 请求在 ApiRequestQueue 里挂到 30 秒
/// 超时 → `errorMessage` 被写上 `DioException [connection error]: ...`。
/// 之后打开 Wi-Fi 点 Retry，nginx 明确记录到
/// `POST /book/datatables/active HTTP/1.1" 200 49483`（书目其实已经拿回来了），
/// 屏幕却纹丝不动。原因就在 `copyWith` 里：
///
/// ```dart
/// errorMessage: errorMessage ?? this.errorMessage,   // 旧写法
/// ```
///
/// `errorMessage` 是 `String?`，传 null 和不传是同一件事，于是全文件所有
/// `copyWith(errorMessage: null)` 都是空操作 —— 错误页成了单向门。
/// 同名的坑在 `selectedTag` / `tagFilteredBooks` 上早就用 `_unset` 哨兵修过，
/// `errorMessage` 被漏了。
void main() {
  group('BooksState.copyWith 的 errorMessage', () {
    const withError = BooksState(errorMessage: 'DioException: offline');

    test('显式传 null 必须能清空（这就是书架卡死的那个 bug）', () {
      expect(
        withError.copyWith(errorMessage: null).errorMessage,
        isNull,
        reason: '清不掉 errorMessage → 书架永远停在错误页，重试看起来没反应',
      );
    });

    test('不传时保持原值', () {
      expect(withError.copyWith().errorMessage, 'DioException: offline');
      expect(
        withError.copyWith(isLoading: true).errorMessage,
        'DioException: offline',
      );
    });

    test('传新值能覆盖', () {
      expect(withError.copyWith(errorMessage: 'boom').errorMessage, 'boom');
    });

    test('isOffline 与 errorMessage 是两件独立的事', () {
      final offline = withError.copyWith(errorMessage: null, isOffline: true);
      expect(offline.errorMessage, isNull);
      expect(offline.isOffline, isTrue);

      // 不传 isOffline 时保持原值
      expect(offline.copyWith(isLoading: true).isOffline, isTrue);
      // 显式传 false 能复位（网络恢复后由 loadBooks 复位）
      expect(offline.copyWith(isOffline: false).isOffline, isFalse);
    });

    test('默认态是「没有离线标记」', () {
      expect(const BooksState().isOffline, isFalse);
    });
  });

  group('SentenceTTSState.copyWith 的 errorMessage', () {
    const withError = SentenceTTSState(errorMessage: 'tts boom');

    test('显式传 null 必须能清空', () {
      expect(withError.copyWith(errorMessage: null).errorMessage, isNull);
    });

    test('不传时保持原值', () {
      expect(withError.copyWith().errorMessage, 'tts boom');
    });
  });
}
