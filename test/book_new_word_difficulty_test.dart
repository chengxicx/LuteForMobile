import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/features/books/models/book_difficulty.dart';
import 'package:song_mobile/shared/utils/book_type_icons.dart';

/// 服务端 datatables 一行里与本特性无关的字段，集中放一份避免重复。
Map<String, dynamic> _baseRow() => {
  'BkID': 7,
  'BkTitle': 'Sample',
  'LgName': 'Japanese',
  'LgID': 2,
  'PageCount': 10,
  'PageNum': 3,
  'WordCount': 1200,
};

void main() {
  group('难度分档阈值（与 lute/book/stats.py 一致）', () {
    test('百分比 → 档位', () {
      expect(BookDifficultyLevel.fromPercent(0), BookDifficulty.easy);
      expect(BookDifficultyLevel.fromPercent(9.9), BookDifficulty.easy);
      expect(BookDifficultyLevel.fromPercent(10), BookDifficulty.challenging);
      expect(BookDifficultyLevel.fromPercent(20), BookDifficulty.challenging);
      expect(BookDifficultyLevel.fromPercent(20.1), BookDifficulty.hard);
      // 还没统计（null）按服务端口径算 EASY，不要显示成 HARD。
      expect(BookDifficultyLevel.fromPercent(null), BookDifficulty.easy);
    });

    test('服务端 label → 档位，认不出的返回 null', () {
      expect(
        BookDifficultyLevel.fromLabel('EASY'),
        BookDifficulty.easy,
      );
      expect(
        BookDifficultyLevel.fromLabel('chal'),
        BookDifficulty.challenging,
      );
      expect(BookDifficultyLevel.fromLabel('HARD'), BookDifficulty.hard);
      expect(BookDifficultyLevel.fromLabel(null), isNull);
      expect(BookDifficultyLevel.fromLabel(''), isNull);
    });
  });

  group('Book 解析新词字段', () {
    test('优先用服务端的 DifficultyLabel', () {
      final book = Book.fromJson({
        ..._baseRow(),
        'NewWordPercent': 27,
        'UnknownPercent': 30,
        'UnknownCount': 412,
        'DistinctCount': 5000,
        'DifficultyLabel': 'HARD',
        'DifficultyColor': 'new-word-hard',
        'DifficultyDescription': 'Hard: over 20% of words are new.',
      });

      expect(book.newWordPercent, 27);
      expect(book.unknownCount, 412);
      expect(book.difficulty, BookDifficulty.hard);
      expect(book.difficulty.label, 'HARD');
      expect(book.newWordPercentOrUnknown, 27);
      expect(book.hasNewWordPercent, true);
      expect(book.difficultyHint, 'Hard: over 20% of words are new.');
    });

    test('没有 DifficultyLabel 时按 NewWordPercent 本地算', () {
      final book = Book.fromJson({..._baseRow(), 'NewWordPercent': 15});
      expect(book.difficulty, BookDifficulty.challenging);
      expect(book.newWordPercentOrUnknown, 15);
    });

    test('NewWordPercent 缺失时退回 UnknownPercent', () {
      final book = Book.fromJson({..._baseRow(), 'UnknownPercent': 5});
      expect(book.newWordPercent, isNull);
      expect(book.newWordPercentOrUnknown, 5);
      expect(book.difficulty, BookDifficulty.easy);
    });

    test('统计没跑过 → hasNewWordPercent 为 false（卡片上显示占位）', () {
      final book = Book.fromJson(_baseRow());
      expect(book.hasNewWordPercent, false);
      // 服务端给空串等同于没给。
      final empty = Book.fromJson({
        ..._baseRow(),
        'NewWordPercent': null,
        'DifficultyLabel': '',
      });
      expect(empty.hasNewWordPercent, false);
      expect(empty.difficultyLabel, isNull);
    });

    test('toJson / fromJson 往返不丢难度字段（书架缓存）', () {
      final book = Book.fromJson({
        ..._baseRow(),
        'NewWordPercent': 12,
        'UnknownCount': 88,
        'DifficultyLabel': 'CHAL',
        'DifficultyColor': 'new-word-chal',
        'DifficultyDescription': 'Challenging: 10-20% of words are new.',
      });
      final round = Book.fromJson(book.toJson());

      expect(round.newWordPercent, 12);
      expect(round.unknownCount, 88);
      expect(round.difficulty, BookDifficulty.challenging);
      expect(round.difficultyHint, 'Challenging: 10-20% of words are new.');
    });
  });

  group('书籍类型图标', () {
    test('存储值 → 图标与品牌色', () {
      expect(BookTypeIcons.of('').icon, Icons.menu_book);
      expect(BookTypeIcons.of('text').icon, Icons.menu_book);
      expect(BookTypeIcons.of('manga').icon, Icons.image_outlined);
      expect(BookTypeIcons.of('manga').color, const Color(0xFFF76707));
      expect(BookTypeIcons.of('youtube').icon, Icons.smart_display);
      expect(BookTypeIcons.of('youtube').color, const Color(0xFFFF0000));
      expect(BookTypeIcons.of('bilibili').icon, Icons.live_tv);
      expect(BookTypeIcons.of('mp3').icon, Icons.headphones);
      expect(BookTypeIcons.of('m4a').icon, Icons.headphones);
      expect(BookTypeIcons.of('netease').icon, Icons.music_note);
      expect(BookTypeIcons.of('video').icon, Icons.movie);
      expect(BookTypeIcons.of('pdf').icon, Icons.picture_as_pdf);
      expect(BookTypeIcons.of('epub').icon, Icons.auto_stories);
      expect(BookTypeIcons.of('webpage').icon, Icons.language);
    });

    test('聚合行与未知类型都有图标', () {
      // 聚合行的 BookType 可能是空串（旧数据），isSeries 必须压过它。
      expect(
        BookTypeIcons.of('', isSeries: true).icon,
        Icons.collections_bookmark,
      );
      expect(BookTypeIcons.of('series').label, 'Book Set');
      // 未知类型回落 Text，不能返回 null。
      expect(BookTypeIcons.of('some-future-type').icon, Icons.menu_book);
      expect(BookTypeIcons.of(null).icon, Icons.menu_book);
    });
  });
}
