import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/content_service.dart';
import 'package:song_mobile/core/network/session_manager.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/outbox_service.dart';
import 'package:song_mobile/core/outbox/outbox_store.dart';
import 'package:song_mobile/features/reader/models/term_form.dart';

// OutboxService 是「地铁里改的状态」能不能活着到服务端的地方。这里用一个假
// ContentService 把网络换成可编程的失败,验证四条关键性质:
//   1. 同一身份只留一条意图(合并)
//   2. 暂时的失败要保住意图并退避,绝不能丢
//   3. 永久失败标记 failed 而不是删除(用户要能看到并重试)
//   4. 一次 flush 不能并发跑第二遍
void main() {
  group('enqueue 合并', () {
    test('同一个词连续双击只留一条意图,状态取最后一次', () async {
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '1');
      await service.enqueueTermStatus(7, '3');
      await service.enqueueTermStatus(7, '99');

      expect(service.intents, hasLength(1));
      expect((service.intents.single as TermEditIntent).status, '99');
    });

    test('裸 status 之后紧跟的表单保存,要把表单快照合并进去', () async {
      // 用户先双击(裸 status),再长按打开表单填了翻译保存 —— 两条意图身份
      // 相同,合并后必须带着 formData,否则 flush 只能去拉服务端当前的字段。
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '1');
      await service.enqueueTermStatus(
        7,
        '99',
        formData: const {'term': '猫', 'translation': 'cat'},
      );

      final intent = service.intents.single as TermEditIntent;
      expect(intent.status, '99');
      expect(intent.formData, isNotNull);
    });

    test('All Known 与随后翻页的 markRead 合并成一条(两个标记都在)', () async {
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: _FakeContent(),
      );

      await service.enqueuePageDone(bookId: 5, pageNum: 12, markKnown: true);
      await service.enqueuePageDone(bookId: 5, pageNum: 12, markRead: true);

      expect(service.intents, hasLength(1));
      final intent = service.intents.single as PageDoneIntent;
      expect(intent.markKnown, isTrue);
      expect(intent.markRead, isTrue);
    });

    test('两个标记都为 false 时不产生意图(空写没有意义)', () async {
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: _FakeContent(),
      );

      await service.enqueuePageDone(bookId: 5, pageNum: 12);

      expect(service.intents, isEmpty);
    });

    test('每次 enqueue 都落盘(进程被杀也不丢)', () async {
      final store = InMemoryOutboxStore();
      final service = OutboxService(store: store, content: _FakeContent());

      await service.enqueueTermStatus(7, '3');

      expect(await store.readAll(), hasLength(1));
    });
  });

  group('seed / 持久化往返', () {
    test('seed 之后 intents 按 seq 升序,且下一次 enqueue 不会撞 seq', () async {
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: _FakeContent(),
      );

      service.seed({
        'term:7': TermEditIntent(termId: 7, status: '3', seq: 9).encode(),
        'term:8': TermEditIntent(termId: 8, status: '1', seq: 2).encode(),
      });

      expect(service.intents.map((i) => i.seq), [2, 9]);

      await service.enqueueTermStatus(9, '99');

      expect(service.intents.map((i) => i.seq), [2, 9, 10]);
    });

    test('单条记录损坏不会连累其它意图', () async {
      // 一个字段被写坏的 JSON 不应该让用户的其它编辑一起消失。
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: _FakeContent(),
      );

      service.seed({
        'term:7': '{"kind":"nope"}',
        'term:8': TermEditIntent(termId: 8, status: '1', seq: 2).encode(),
      });

      expect(service.intents, hasLength(1));
      expect(service.intents.single.coalesceKey, 'term:8');
    });
  });

  group('flush 成功路径', () {
    test('发出后从队列和存储里都删掉,并回调 onSent', () async {
      final store = InMemoryOutboxStore();
      final content = _FakeContent();
      final service = OutboxService(store: store, content: content);
      final sent = <PendingIntent>[];
      service.onSent = sent.addAll;

      await service.enqueueTermStatus(7, '3');
      await service.enqueuePageDone(bookId: 5, pageNum: 12, markRead: true);
      await service.flush();

      expect(service.intents, isEmpty);
      expect(await store.readAll(), isEmpty);
      expect(sent, hasLength(2));
      expect(content.edits, [7]);
      expect(content.pageDones, [(5, 12, false)]);
    });

    test('裸 status 会先取表单再提交完整词条(不把翻译清空)', () async {
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3');
      await service.flush();

      expect(content.formFetches, [7]);
      final payload = content.editPayloads.single;
      expect(payload['status'], '3');
      expect(payload['translation'], 'cat', reason: '服务端原有字段要保住');
    });

    test('带表单快照时不再取表单,且 status 以意图为准', () async {
      // 「先保存表单(表单里 status=1),再双击改成 99」合并之后,快照里的
      // status 是旧的,必须以意图的为准。
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(
        7,
        '99',
        formData: const {'term': '猫', 'status': '1', 'translation': 'cat'},
      );
      await service.flush();

      expect(content.formFetches, isEmpty);
      expect(content.editPayloads.single['status'], '99');
    });

    test('markKnown 发的是 restknown=1(超集),不会只发 markRead', () async {
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueuePageDone(
        bookId: 5,
        pageNum: 12,
        markRead: true,
        markKnown: true,
      );
      await service.flush();

      expect(content.pageDones, [(5, 12, true)]);
    });

    test('新建词条走 saveTermForm,带 langId 和文本', () async {
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermCreate(42, '犬', const {'term': '犬'});
      await service.flush();

      expect(content.created, [(42, '犬')]);
    });
  });

  group('flush 失败路径', () {
    // 这些用例都带 formData 入队,好让失败落在 editTerm 这一步:裸 status 会
    // 先拉表单,异常会在那一步抛出,计数就看不出来了。
    const snapshot = {'term': '猫', 'translation': 'cat'};

    test('连接失败:意图保住、退避、不算失败', () async {
      final store = InMemoryOutboxStore();
      final content = _FakeContent()..failWith = _connectionError;
      final service = OutboxService(store: store, content: content);

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.flush();

      expect(service.intents, hasLength(1), reason: '离线时绝不能丢意图');
      final intent = service.intents.single;
      expect(intent.failed, isFalse);
      expect(intent.attempts, 1);
      expect(intent.nextAttemptAtMs, greaterThan(0));
      expect(await store.readAll(), hasLength(1), reason: '退避也要落盘');
    });

    test('退避中的意图不会立刻被再发一次', () async {
      final content = _FakeContent()..failWith = _connectionError;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.flush();
      final afterFirst = content.editAttempts;

      await service.flush();

      expect(content.editAttempts, afterFirst, reason: '退避期内不该重试');
    });

    test('一条暂时失败会中止整轮(后面的同样发不出去)', () async {
      final content = _FakeContent()..failWith = _connectionError;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.enqueueTermStatus(8, '3', formData: snapshot);
      await service.flush();

      expect(content.editAttempts, 1, reason: '第二条不该被白白尝试');
      expect(service.intents, hasLength(2));
    });

    test('永久失败标记 failed 但保留(用户要能看到并重试)', () async {
      final content = _FakeContent()..failWith = _notFound;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.flush();

      expect(service.intents, hasLength(1));
      expect(service.intents.single.failed, isTrue);
    });

    test('标记 failed 之后不再重发', () async {
      final content = _FakeContent()..failWith = _notFound;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.flush();
      final afterFirst = content.editAttempts;

      await service.flush();

      expect(content.editAttempts, afterFirst);
    });

    test('会话过期:保留意图、不标 failed、且中止整轮', () async {
      final content = _FakeContent()..failWith = _loginRequired;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.enqueueTermStatus(8, '3', formData: snapshot);
      await service.flush();

      expect(service.intents, hasLength(2), reason: '重新登录后必须还能同步');
      expect(service.intents.any((i) => i.failed), isFalse);
      expect(content.editAttempts, 1, reason: '第二条会以同样方式失败');
    });

    test('一条成功、后一条断连:成功的仍要报告 onSent', () async {
      // 否则那条已落地的编辑,它的页面缓存会一直留着同步前的旧状态。
      final content = _FakeContent()
        ..failAfterEdits = 1
        ..failWith = _connectionError;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );
      final sent = <PendingIntent>[];
      service.onSent = sent.addAll;

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.enqueueTermStatus(8, '3', formData: snapshot);
      await service.flush();

      expect(sent, hasLength(1));
      expect((sent.single as TermEditIntent).termId, 7);
      expect(service.intents, hasLength(1), reason: '失败的那条要留下');
    });

    test('retry() 把 failed 的意图重新武装,下一次 flush 会发出去', () async {
      final content = _FakeContent()..failWith = _notFound;
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3', formData: snapshot);
      await service.flush();
      expect(service.intents.single.failed, isTrue);

      content.failWith = null;
      await service.retry('term:7');
      await service.flush();

      expect(service.intents, isEmpty);
      expect(content.edits, [7]);
    });
  });

  group('flush 并发', () {
    test('第二次 flush 在第一次跑完前直接返回(单飞)', () async {
      // 可达性翻转和 30 秒定时器可能同时触发;两条并发的 flush 会把同一条
      // 意图发两遍。
      final content = _FakeContent()..delay = const Duration(milliseconds: 50);
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3');
      final first = service.flush();
      final second = service.flush();
      await Future.wait([first, second]);

      expect(content.editAttempts, 1);
      expect(service.intents, isEmpty);
    });

    test('flush 期间 isFlushing 为真,结束后复位', () async {
      final content = _FakeContent()..delay = const Duration(milliseconds: 30);
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      await service.enqueueTermStatus(7, '3');
      final future = service.flush();

      expect(service.isFlushing, isTrue);
      await future;
      expect(service.isFlushing, isFalse);
    });
  });

  group('clearAll', () {
    test('清空队列和存储', () async {
      final store = InMemoryOutboxStore();
      final service = OutboxService(store: store, content: _FakeContent());

      await service.enqueueTermStatus(7, '3');
      await service.enqueuePageDone(bookId: 5, pageNum: 12, markRead: true);
      await service.clearAll();

      expect(service.intents, isEmpty);
      expect(await store.readAll(), isEmpty);
    });
  });

  group('重放必须绕过 ApiRequestQueue', () {
    // ApiRequestQueue 会把请求吞进内存队列:没有 session 拦截器(重放必然
    // 401)、重放失败一次就丢、第二次 GET /read/edit_term/... 直接拒绝。outbox
    // 的契约与之完全相反,所以每一条重放都必须带 bypassQueue: true —— 否则
    // 在地铁里改的状态会永远停在「待同步」,既不到服务端,也不会走退避。
    test('四类重放全部带 bypassQueue', () async {
      final content = _FakeContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
      );

      // 覆盖到全部四条重放路径:裸 status(取表单 + 提交)、带快照的编辑、
      // 新建词条、整页标记。
      await service.enqueueTermStatus(7, '3');
      await service.enqueueTermStatus(
        8,
        '99',
        formData: const {'term': '犬', 'translation': 'dog'},
      );
      await service.enqueueTermCreate(42, '鳥', const {'term': '鳥'});
      await service.enqueuePageDone(
        bookId: 5,
        pageNum: 12,
        markKnown: true,
      );

      await service.flush();

      expect(service.intents, isEmpty, reason: '全部应已送出');
      expect(content.formFetches, [7]);
      expect(content.edits, [7, 8]);
      expect(content.created, [(42, '鳥')]);
      expect(content.pageDones, [(5, 12, true)]);
      expect(
        content.queueBypass,
        everyElement(isTrue),
        reason: '任何一条重放落进队列都会丢,见上面的注释',
      );
      expect(content.queueBypass, isNotEmpty);
    });
  });
}

// --- 假的 ContentService ---
//
// 只实现 outbox 真正会调到的五个方法,其余靠 noSuchMethod 兜住 —— 否则要
// 抄 1300 行接口。

DioException _connectionError() => DioException(
  requestOptions: RequestOptions(path: '/read/edit_term/7'),
  type: DioExceptionType.connectionError,
  error: 'offline',
);

DioException _notFound() => DioException(
  requestOptions: RequestOptions(path: '/read/edit_term/7'),
  response: Response(
    requestOptions: RequestOptions(path: '/read/edit_term/7'),
    statusCode: 404,
  ),
  type: DioExceptionType.badResponse,
);

Exception _loginRequired() => const ServerLoginRequiredException();

class _FakeContent implements ContentService {
  /// A factory so each failing case gets a fresh exception instance.
  Object Function()? failWith;

  /// Let the first N [editTerm] calls through before [failWith] starts to
  /// apply.  Used to build "this one lands, then the link drops".
  int failAfterEdits = 0;

  Duration? delay;

  final List<int> edits = [];
  final List<Map<String, dynamic>> editPayloads = [];
  final List<int> formFetches = [];
  final List<(int, int, bool)> pageDones = [];
  final List<(int, String)> created = [];

  /// Every `bypassQueue` flag the service passed, in call order.
  ///
  /// A replay that fell into `ApiRequestQueue` would be dropped after one
  /// attempt, replayed without a session cookie, and refused outright for the
  /// second `GET /read/edit_term/...` -- so the tests assert this is all-true
  /// rather than merely recording it.
  final List<bool> queueBypass = [];

  int editAttempts = 0;

  Future<void> _maybeFail() async {
    if (delay != null) await Future<void>.delayed(delay!);
    final failure = failWith;
    if (failure != null) throw failure();
  }

  @override
  Future<void> editTerm(
    int termId,
    Map<String, dynamic> data, {
    bool bypassQueue = false,
  }) async {
    editAttempts++;
    queueBypass.add(bypassQueue);
    if (delay != null) await Future<void>.delayed(delay!);

    final failure = failWith;
    if (failure != null && editAttempts > failAfterEdits) throw failure();

    edits.add(termId);
    editPayloads.add(data);
  }

  @override
  Future<TermForm> getTermFormById(
    int termId, {
    bool bypassQueue = false,
  }) async {
    formFetches.add(termId);
    queueBypass.add(bypassQueue);
    await _maybeFail();
    return TermForm(
      term: '猫',
      translation: 'cat',
      termId: termId,
      languageId: 42,
      status: '1',
      syncStatus: true,
    );
  }

  @override
  Future<void> saveTermForm(
    int langId,
    String text,
    Map<String, dynamic> data, {
    bool bypassQueue = false,
  }) async {
    queueBypass.add(bypassQueue);
    await _maybeFail();
    created.add((langId, text));
  }

  @override
  Future<void> markPageReadOnly(
    int bookId,
    int pageNum, {
    bool bypassQueue = false,
  }) async {
    queueBypass.add(bypassQueue);
    await _maybeFail();
    pageDones.add((bookId, pageNum, false));
  }

  @override
  Future<void> markPageKnownOnly(
    int bookId,
    int pageNum, {
    bool bypassQueue = false,
  }) async {
    queueBypass.add(bypassQueue);
    await _maybeFail();
    pageDones.add((bookId, pageNum, true));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
