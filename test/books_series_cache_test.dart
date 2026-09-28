import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:song_mobile/core/cache/books_cache_service.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/hive_registrar.g.dart';

// 书架上的 Book Set 聚合行是从书架缓存里画出来的，所以断网也看得见、点得进去；
// 但点进去的成员列表原先只能打网络，于是离线就永远停在 "Loading books..."。
// 系列成员缓存就是补这个洞的，这里锁住它真的能存能取。
//
// 缓存解不开时必须返回 null 而不是抛：这一层只是加速，坏了不能让页面变错误态。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('lute_books_series_cache');
    Hive.init(tempDir.path);
    Hive.registerAdapters();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Book book(int id, {String lang = 'Japanese'}) => Book(
    id: id,
    title: 'Book $id',
    language: lang,
    langId: 7,
    totalPages: 45,
    currentPage: 1,
    percent: 2,
    wordCount: 1200,
    distinctTerms: 300,
    unknownPct: 5.5,
    statusDistribution: const [10, 20, 30, 40, 50],
    seriesTag: 'ai-story',
  );

  test('没存过时返回 null', () async {
    final service = BooksCacheService();
    await service.initialize();

    expect(await service.getSeriesBooks('never-saved'), isNull);
  });

  test('存进去的成员书能原样取回来', () async {
    final service = BooksCacheService();
    await service.initialize();

    await service.saveSeriesBooks('ai-story', [book(1), book(2)]);

    final back = await service.getSeriesBooks('ai-story');
    expect(back, isNotNull);
    expect(back!.map((b) => b.id), [1, 2]);
    expect(back.first.title, 'Book 1');
    expect(back.first.seriesTag, 'ai-story');
  });

  test('不同 tag 互不串味', () async {
    final service = BooksCacheService();
    await service.initialize();

    await service.saveSeriesBooks('set-a', [book(11)]);
    await service.saveSeriesBooks('set-b', [book(21), book(22)]);

    expect((await service.getSeriesBooks('set-a'))!.map((b) => b.id), [11]);
    expect((await service.getSeriesBooks('set-b'))!.map((b) => b.id), [21, 22]);
  });

  test('归档与非归档是两个键', () async {
    final service = BooksCacheService();
    await service.initialize();

    await service.saveSeriesBooks('dup', [book(31)]);
    await service.saveSeriesBooks('dup', [book(41), book(42)], archived: true);

    expect((await service.getSeriesBooks('dup'))!.map((b) => b.id), [31]);
    expect(
      (await service.getSeriesBooks('dup', archived: true))!.map((b) => b.id),
      [41, 42],
    );
  });

  test('clearAll 会连系列缓存一起清掉', () async {
    final service = BooksCacheService();
    await service.initialize();

    await service.saveSeriesBooks('to-clear', [book(51)]);
    expect(await service.getSeriesBooks('to-clear'), isNotNull);

    await service.clearAll();

    expect(await service.getSeriesBooks('to-clear'), isNull);
  });
}
