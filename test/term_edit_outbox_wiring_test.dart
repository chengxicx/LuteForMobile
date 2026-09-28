import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/content_service.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/outbox_service.dart';
import 'package:song_mobile/core/outbox/outbox_store.dart';
import 'package:song_mobile/core/outbox/providers/outbox_provider.dart';
import 'package:song_mobile/features/reader/models/term_form.dart';
import 'package:song_mobile/features/terms/widgets/term_edit_dialog_wrapper.dart';

// 词条编辑器的保存原先直接 `contentService.editTerm(...)`，绕过了 outbox ——
// 地铁里保存失败就是「Failed to update term」加一条丢掉的编辑。它现在走
// `queueTermFormEdit`，这里锁住三件事：
//
//   1. 有 id 的表单编辑变成一条 TermEditIntent，**带着完整表单快照**（否则
//      重放只能去拉服务端当前的字段，等于把用户没动过的字段覆盖成别人的值）；
//   2. 没有 id 的词走 TermCreateIntent，而不是 `termId!` 直接崩；
//   3. 入队全程不碰网络 —— 断网正是它要成立的前提。
void main() {
  late ProviderContainer container;
  late OutboxService service;

  setUp(() {
    service = OutboxService(
      store: InMemoryOutboxStore(),
      // 任何网络调用都会立刻抛 —— 既是占位，也是断言：入队不该有网络副作用。
      content: _NeverCalledContent(),
    );

    container = ProviderContainer(
      overrides: [outboxServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
  });

  OutboxNotifier outbox() => container.read(outboxProvider.notifier);

  TermForm form({int? termId = 7, String status = '3'}) => TermForm(
    term: '猫',
    translation: 'cat',
    termId: termId,
    languageId: 42,
    status: status,
    syncStatus: true,
  );

  test('表单编辑进 outbox,带完整快照,不直接发请求', () async {
    await queueTermFormEdit(outbox(), form());

    expect(service.intents, hasLength(1));
    final intent = service.intents.single as TermEditIntent;
    expect(intent.termId, 7);
    expect(intent.status, '3');
    expect(intent.langId, 42);
    expect(
      intent.formData,
      isNotNull,
      reason: '没有快照的话 flush 得先去拉表单，用户没动过的字段就会被服务端的现值顶掉',
    );
    expect(intent.formData!['text'], '猫', reason: 'toFormData() 用的键是 text');
    expect(intent.formData!['translation'], 'cat');
  });

  test('没有 id 的词走「新建」意图,而不是 termId! 崩掉', () async {
    await queueTermFormEdit(outbox(), form(termId: null));

    expect(service.intents, hasLength(1));
    final intent = service.intents.single as TermCreateIntent;
    expect(intent.langId, 42);
    expect(intent.text, '猫');
  });

  test('先改表单再双击改状态:合并成一条,表单快照要留住', () async {
    await queueTermFormEdit(outbox(), form(status: '3'));

    // 阅读页双击只带 status（见 reader_screen 的 enqueueTermStatus）。
    await outbox().enqueueTermStatus(7, '99', langId: 42);

    expect(service.intents, hasLength(1), reason: '同一个词只该有一条意图');
    final intent = service.intents.single as TermEditIntent;
    expect(intent.status, '99', reason: '状态取最后一次双击');
    expect(
      intent.formData,
      isNotNull,
      reason: '双击不能把用户刚填的表单字段顶掉',
    );
  });
}

/// 入队路径不该碰网络。任何被调用到的方法都直接抛，好让「偷偷发了一次请求」
/// 变成一个刺眼的测试失败，而不是静默通过。
class _NeverCalledContent implements ContentService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('入队不该调用 ContentService.${invocation.memberName}');
}
