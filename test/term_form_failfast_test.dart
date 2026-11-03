// 离线长按建卡为什么要等 18 秒，以及现在为什么不用等。
//
// 真机（飞行模式）实测：长按 `所` 后约 18 秒才回落本地表单。这条请求以前
// 走的是 app 的全局预算：Dio 默认 10 秒超时 → 失败后拦截器再做一次 5–8 秒
// 的服务器健康探测 → 还（可能）被 ApiRequestQueue 扣住等 30 秒上限。
//
// 现在三层收紧：
//   1. `ReaderNotifier.fetchTermForm*` 已知不可达就直接返回 null（不发请求）；
//   2. `/read/edit_term/<id>`、`/read/termform/...` 用 2 秒连接 + 3 秒接收上限；
//   3. 这两个端点带 `failFast`，失败时跳过健康探测、不重试、不排队。
//
// 运行：flutter test test/term_form_failfast_test.dart

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/cache/term_cache_service.dart';
import 'package:song_mobile/core/network/api_request_queue.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/content_service.dart';
import 'package:song_mobile/features/reader/models/term_form.dart';
import 'package:song_mobile/features/reader/providers/reader_provider.dart';
import 'package:song_mobile/features/reader/repositories/reader_repository.dart';
import 'package:song_mobile/features/reader/services/page_cache_service.dart';
import 'package:song_mobile/shared/providers/server_status_provider.dart';

/// 只数调用次数、不碰网络的仓库：离线时它一次都不该被调用。
class _CountingRepository extends ReaderRepository {
  _CountingRepository()
    : super(
        contentService: ContentService(
          apiService: ApiService(baseUrl: 'http://example.invalid/'),
          pageCacheService: PageCacheService(),
          termCacheService: TermCacheService(),
        ),
      );

  int byIdCalls = 0;
  int withDetailsCalls = 0;

  @override
  Future<TermForm> getTermFormByIdWithParentDetails(int termId) async {
    byIdCalls++;
    return TermForm(
      term: '所',
      termId: termId,
      languageId: 13,
      status: '1',
      syncStatus: true,
    );
  }

  @override
  Future<TermForm> getTermFormWithParentDetails(
    int langId,
    String text,
  ) async {
    withDetailsCalls++;
    return TermForm(
      term: text,
      languageId: langId,
      status: '1',
      syncStatus: true,
    );
  }
}

/// 记录最终真正发出去了什么，不连网。
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      '<html></html>',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.textPlainContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    ApiRequestQueue().dispose();
    ServerStatusManager.setReachable(true);
  });

  tearDown(() {
    ApiRequestQueue().dispose();
    ServerStatusManager.setReachable(true);
  });

  group('ReaderNotifier 的建卡请求在已知离线时 fail-fast', () {
    late _CountingRepository repo;
    late ProviderContainer container;

    setUp(() {
      repo = _CountingRepository();
      container = ProviderContainer(
        overrides: [readerRepositoryProvider.overrideWithValue(repo)],
      );
    });

    tearDown(() => container.dispose());

    test('离线：不发请求，立刻返回 null（调用方随即开本地表单）', () async {
      ServerStatusManager.setReachable(false);

      final stopwatch = Stopwatch()..start();
      final form = await container
          .read(readerProvider.notifier)
          .fetchTermFormById(42);
      stopwatch.stop();

      expect(form, isNull);
      expect(repo.byIdCalls, 0, reason: '已知不可达就不该再发往返');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 500)),
        reason: '离线失败必须是本地判断，不能等网络超时',
      );
    });

    test('离线：多选建卡（按词面）同样立刻返回 null', () async {
      ServerStatusManager.setReachable(false);

      final stopwatch = Stopwatch()..start();
      final form = await container
          .read(readerProvider.notifier)
          .fetchTermFormWithDetails(13, '香山さんに');
      stopwatch.stop();

      expect(form, isNull);
      expect(repo.withDetailsCalls, 0);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('在线：照常走服务器表单', () async {
      final form = await container
          .read(readerProvider.notifier)
          .fetchTermFormById(42);

      expect(repo.byIdCalls, 1);
      expect(form?.termId, 42);
    });
  });

  test('词卡表单请求带短超时和 failFast，不走全局 10 秒预算', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://example.invalid/'));
    final adapter = _CapturingAdapter();
    dio.httpClientAdapter = adapter;
    final api = ApiService(baseUrl: 'http://example.invalid/', dio: dio);
    // 队列是单例，且 dispose 不复位 _serverUrl：换一个 URL 重新初始化，
    // 它的可达性标志才会跟着 ServerStatusManager（上面已置 true）同步。
    ApiRequestQueue().initialize('http://example.invalid/termform-check/', dio);

    await api.getTermFormById(42);

    final sent = adapter.last;
    expect(sent, isNotNull);
    expect(sent!.connectTimeout, ApiService.termFormConnectTimeout);
    expect(sent.receiveTimeout, ApiService.termFormReceiveTimeout);
    expect(sent.extra['failFast'], isTrue);
    expect(sent.extra['noQueue'], isTrue);
  });
}
