import 'package:flutter/material.dart';

/// 一种书籍类型的图标 + 品牌色 + 名称。
class BookTypeIcon {
  final IconData icon;
  final Color color;
  final String label;

  const BookTypeIcon({
    required this.icon,
    required this.color,
    required this.label,
  });
}

/// 书籍类型（books.BkBookType）→ 图标。
///
/// 图标与配色对齐服务端的单一注册表 `lute/book/types.py BOOK_TYPES`
/// （web 端由 static/js/book-type-icons.js 渲染同一套）。
/// 服务端的 key 与这里必须一一对应，新增类型时两边一起改。
class BookTypeIcons {
  BookTypeIcons._();

  static const BookTypeIcon text = BookTypeIcon(
    icon: Icons.menu_book,
    color: Color(0xFF3B82F6),
    label: 'Text',
  );

  static const BookTypeIcon webpage = BookTypeIcon(
    icon: Icons.language,
    color: Color(0xFF0C8599),
    label: 'Web page',
  );

  static const BookTypeIcon youtube = BookTypeIcon(
    icon: Icons.smart_display,
    color: Color(0xFFFF0000),
    label: 'YouTube',
  );

  static const BookTypeIcon bilibili = BookTypeIcon(
    icon: Icons.live_tv,
    color: Color(0xFF00A1D6),
    label: 'Bilibili',
  );

  static const BookTypeIcon mp3 = BookTypeIcon(
    icon: Icons.headphones,
    color: Color(0xFF2F9E44),
    label: 'MP3',
  );

  static const BookTypeIcon netease = BookTypeIcon(
    icon: Icons.music_note,
    color: Color(0xFFC20C0C),
    label: 'NetEase',
  );

  static const BookTypeIcon video = BookTypeIcon(
    icon: Icons.movie,
    color: Color(0xFF845EF7),
    label: 'Video',
  );

  static const BookTypeIcon manga = BookTypeIcon(
    icon: Icons.image_outlined,
    color: Color(0xFFF76707),
    label: 'Manga',
  );

  static const BookTypeIcon pdf = BookTypeIcon(
    icon: Icons.picture_as_pdf,
    color: Color(0xFFE03131),
    label: 'PDF',
  );

  static const BookTypeIcon epub = BookTypeIcon(
    icon: Icons.auto_stories,
    color: Color(0xFFD6336C),
    label: 'EPUB',
  );

  /// tag 聚合行（Book Set）。它不是真正的书，只是列表里的一行汇总。
  static const BookTypeIcon series = BookTypeIcon(
    icon: Icons.collections_bookmark,
    color: Color(0xFF4C6EF5),
    label: 'Book Set',
  );

  /// [bookType] 是存储的 `BkBookType` 值（''、'manga'、'youtube' …）。
  ///
  /// [isSeries] 为 true 时强制返回 [series]（聚合行的 BookType 也可能是
  /// 空的旧数据）。未知类型回落 [text]，保证卡片永远有图标。
  static BookTypeIcon of(String? bookType, {bool isSeries = false}) {
    if (isSeries) return series;
    switch ((bookType ?? '').trim().toLowerCase()) {
      case 'manga':
        return manga;
      case 'youtube':
        return youtube;
      case 'bilibili':
        return bilibili;
      case 'mp3':
      case 'm4a':
        return mp3;
      case 'netease':
        return netease;
      case 'video':
        return video;
      case 'pdf':
        return pdf;
      case 'epub':
        return epub;
      case 'webpage':
        return webpage;
      case 'series':
        return series;
      default:
        return text;
    }
  }
}
