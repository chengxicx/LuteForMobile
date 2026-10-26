// 断网时长按 / 多选还能不能开词卡。
//
// 背景（真机反馈，飞行模式下）：多选两个词松手后什么都不弹，像是手势没生效。
//
// 根因：词卡的内容一律从服务器要（`getTermForm` / `getTermFormById`，各要
// 一次往返）。断网时请求抛异常，上层 `fetchTermForm` 返回 null，两个调用点
// 都是 `if (termForm != null) 打开`，于是**卡片根本不出现**。
//
// 现在拿不到服务器表单时用 [buildOfflineTermForm] 拼一张：词与状态来自页面，
// 释义/读音来自本机词条缓存（`termCacheService`），词典区本来就走本机词典
// 池，所以断网也能查。
//
// 运行：flutter test test/offline_term_form_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/providers/reader_provider.dart';

void main() {
  test('新词（多选拼出来的）没有 termId，标记为未同步', () {
    final form = buildOfflineTermForm(
      languageId: 13,
      text: '香山さんに',
      statusClass: 'status0',
    );

    expect(form.term, '香山さんに');
    expect(form.termId, isNull);
    expect(form.languageId, 13);
    // status0 = 还没学，新词默认为 1（learning 1）
    expect(form.status, '1');
    expect(form.translation, isNull);
    expect(form.romanization, isNull);
    // 服务器上还没有这条词，卡片应显示"待同步"
    expect(form.syncStatus, isFalse);
  });

  test('已有词条：状态取自页面，且视为已同步', () {
    final form = buildOfflineTermForm(
      languageId: 13,
      text: '出会う',
      termId: 4242,
      statusClass: 'status4',
      translation: ' 相遇 ',
      romanization: 'であう',
    );

    expect(form.termId, 4242);
    expect(form.status, '4');
    expect(form.syncStatus, isTrue);
    // 缓存里的值要去掉首尾空白，否则会原样写回服务器
    expect(form.translation, '相遇');
    expect(form.romanization, 'であう');
  });

  test('缓存里的空白释义当作没有，不要留空串', () {
    final form = buildOfflineTermForm(
      languageId: 13,
      text: '美しい',
      termId: 7,
      translation: '   ',
      romanization: '',
    );

    expect(form.translation, isNull);
    expect(form.romanization, isNull);
  });

  test('页面状态解析不出来时退回 learning 1，不崩', () {
    final form = buildOfflineTermForm(
      languageId: 1,
      text: 'word',
      termId: 9,
      statusClass: 'unknown',
    );

    expect(form.status, '1');
  });

  test('表单快照能直接提交（toFormData 不依赖服务器字段）', () {
    final form = buildOfflineTermForm(
      languageId: 13,
      text: '美しい',
      termId: 7,
      translation: '美丽',
    );

    final data = form.toFormData();
    expect(data['translation'], '美丽');
    expect(data['status'], '1');
  });
}
