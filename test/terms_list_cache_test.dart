import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/terms_list_cache_service.dart';
import 'package:song_mobile/features/terms/models/term.dart';

// 词条屏的离线快照：断网时列表按「过滤条件组合」从快照原样恢复，这是
// 「地铁里改词义」可用的前提。这里锁住它真的能存能取、过滤组合不串味。
//
// 缓存解不开时必须返回 null 而不是抛：这一层只是兜底，坏了不能让页面变错误态。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_terms_list_cache');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Term term(int id, {String text = '言う', String status = '1'}) => Term(
    id: id,
    text: '$text$id',
    translation: 'say $id',
    status: status,
    langId: 7,
    language: 'Japanese',
    tags: ['jlpt-n5'],
  );

  test('没存过时返回 null', () async {
    final service = TermsListCacheService();
    await service.initialize();

    expect(
      await service.getTerms(
        langId: 7,
        search: '',
        statuses: {'1', '2'},
      ),
      isNull,
    );
  });

  test('存进去的列表能原样取回来', () async {
    final service = TermsListCacheService();
    await service.initialize();

    await service.saveTerms(
      [term(1), term(2, status: '99')],
      langId: 7,
      search: '',
      statuses: {'1', '2', '99'},
    );

    final back = await service.getTerms(
      langId: 7,
      search: '',
      statuses: {'1', '2', '99'},
    );
    expect(back, isNotNull);
    expect(back!.length, 2);
    expect(back.first.id, 1);
    expect(back.first.text, '言う1');
    expect(back.first.tags, ['jlpt-n5']);
    expect(back.last.status, '99');
  });

  test('不同过滤组合互不串味', () async {
    final service = TermsListCacheService();
    await service.initialize();

    await service.saveTerms([term(1)], langId: 7, search: '', statuses: {'1'});
    await service.saveTerms(
      [term(2)],
      langId: 7,
      search: '',
      statuses: {'99'},
    );
    await service.saveTerms(
      [term(3)],
      langId: 7,
      search: '言',
      statuses: {'1'},
    );

    expect(
      (await service.getTerms(langId: 7, search: '', statuses: {'1'}))!.first.id,
      1,
    );
    expect(
      (await service.getTerms(
        langId: 7,
        search: '',
        statuses: {'99'},
      ))!.first.id,
      2,
    );
    expect(
      (await service.getTerms(
        langId: 7,
        search: '言',
        statuses: {'1'},
      ))!.first.id,
      3,
    );
  });

  test('statuses 的键与顺序无关', () async {
    final service = TermsListCacheService();
    await service.initialize();

    await service.saveTerms(
      [term(1)],
      langId: 7,
      search: '',
      statuses: {'1', '2', '99'},
    );

    // 同一组 statuses 换个顺序写，必须命中同一份快照。
    final back = await service.getTerms(
      langId: 7,
      search: '',
      statuses: {'99', '1', '2'},
    );
    expect(back, isNotNull);
    expect(back!.single.id, 1);
  });

  test('langId 不同是两个键', () async {
    final service = TermsListCacheService();
    await service.initialize();

    await service.saveTerms([term(1)], langId: 7, search: '', statuses: {'1'});
    await service.saveTerms([term(2)], langId: 8, search: '', statuses: {'1'});

    expect(
      (await service.getTerms(langId: 7, search: '', statuses: {'1'}))!.first.id,
      1,
    );
    expect(
      (await service.getTerms(langId: 8, search: '', statuses: {'1'}))!.first.id,
      2,
    );
  });

  test('clearAll 清掉全部过滤组合', () async {
    final service = TermsListCacheService();
    await service.initialize();

    await service.saveTerms([term(1)], langId: 7, search: '', statuses: {'1'});
    expect(
      await service.getTerms(langId: 7, search: '', statuses: {'1'}),
      isNotNull,
    );

    await service.clearAll();

    expect(
      await service.getTerms(langId: 7, search: '', statuses: {'1'}),
      isNull,
    );
  });
}
