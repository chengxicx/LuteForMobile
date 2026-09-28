import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/terms/models/term.dart';
import 'package:song_mobile/features/terms/providers/terms_provider.dart';

/// 词条屏「断网不要把 DioException 原文拍在屏幕上」的回归测试，与
/// books_load_failure_test.dart 锁的是同一条约定：
///
/// 判据是 `ServerStatusManager.isReachable`（拦截器判定不可达时会
/// `markError()`），标志为假 =「根本没连上」→ 记成可自愈的 Offline 态；
/// 标志为真 =「服务器真的回了错」→ 才如实显示原文。
void main() {
  group('TermsNotifier.classifyLoadFailure', () {
    test('连不上服务端 → 不显示错误原文，改标记为离线', () {
      final (message, offline) = TermsNotifier.classifyLoadFailure(
        error: Exception('DioException [connection error]: null'),
        serverReachable: false,
      );
      expect(
        message,
        isNull,
        reason: '离线是可自愈的状态，不该把 DioException 原文给用户看',
      );
      expect(offline, isTrue);
    });

    test('服务端可达但请求失败 → 显示原文，且不算离线', () {
      final (message, offline) = TermsNotifier.classifyLoadFailure(
        error: Exception('500 Internal Server Error'),
        serverReachable: true,
      );
      expect(message, contains('500 Internal Server Error'));
      expect(
        offline,
        isFalse,
        reason: '服务器回了错不是离线，否则界面会显示 Offline 页并等一个永远不会来的自动恢复',
      );
    });

    test('errorMessage 与 isOffline 不能同时有效', () {
      // 两者同时成立会让 terms_screen 在错误页和 Offline 页之间打架。
      for (final reachable in [true, false]) {
        final (message, offline) = TermsNotifier.classifyLoadFailure(
          error: Exception('boom'),
          serverReachable: reachable,
        );
        expect(
          message == null || !offline,
          isTrue,
          reason: 'reachable=$reachable 时两者同时有效',
        );
      }
    });
  });

  group('TermsState.isOffline', () {
    test('默认不是离线', () {
      expect(const TermsState().isOffline, isFalse);
    });

    test('isOffline 与 errorMessage 是两件独立的事', () {
      const withError = TermsState(errorMessage: 'boom');
      final offline = withError.copyWith(errorMessage: null, isOffline: true);
      expect(offline.errorMessage, isNull);
      expect(offline.isOffline, isTrue);

      // 不传 isOffline 时保持原值
      expect(offline.copyWith(isLoading: true).isOffline, isTrue);
      expect(offline.copyWith(isOffline: false).isOffline, isFalse);
    });
  });

  group('Term toJson/fromJson round-trip', () {
    // 词条屏的离线快照（terms_list_cache）靠这对序列化原样恢复列表，
    // round-trip 丢字段就会断网时显示出错的数据。
    test('字段无损往返', () {
      final term = Term(
        id: 42,
        text: '言う',
        translation: 'say',
        status: '2',
        langId: 7,
        language: 'Japanese',
        tags: ['jlpt-n5', 'verb'],
        parentCount: 3,
      );

      final back = Term.fromJson(term.toJson());
      expect(back.id, 42);
      expect(back.text, '言う');
      expect(back.translation, 'say');
      expect(back.status, '2');
      expect(back.langId, 7);
      expect(back.language, 'Japanese');
      expect(back.tags, ['jlpt-n5', 'verb']);
      expect(back.parentCount, 3);
    });

    test('createdDate 往返不丢', () {
      final term = Term(
        id: 1,
        text: 'x',
        status: '1',
        langId: 1,
        language: 'Japanese',
        createdDate: DateTime.parse('2026-09-28T10:00:00.000'),
      );
      expect(Term.fromJson(term.toJson()).createdDate,
          term.createdDate);
    });
  });
}
