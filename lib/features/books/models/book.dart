import 'dart:convert';

import 'book_difficulty.dart';

class Book {
  /// 服务端用来标记「tag 聚合行」的 BookType 取值。
  ///
  /// 当某个 tag 被配置成 Book Set（UserSetting `book_series_tags`）后，
  /// 服务端不再把该 tag 下的每本书单独返回，而是聚合成**一行**：
  /// `BkID = NULL`、`BkTitle = tag 名`、`BookType = 'series'`、
  /// `PageCount = 该 tag 下的书数`（见 lute/book/datatables.py 的 series_branch）。
  static const String seriesBookType = 'series';

  final int id;
  final String title;
  final String language;
  final int? langId;
  final int totalPages;
  final int currentPage;
  final int percent;
  final int wordCount;
  final int? distinctTerms;

  /// 生词（status 0）的词数，服务端 `bookstats.distinctunknowns`。
  final int? unknownCount;

  final double? unknownPct;

  /// 「新词」占比（0-100），服务端 `bookstats.new_word_percent`。
  ///
  /// 它和 [unknownPct] 不是一回事：UnknownPercent 是「未掌握词」占比，
  /// NewWordPercent 只算从没见过的词。难度分档用的是后者。
  final double? newWordPercent;

  /// 服务端算好的难度档位（`DifficultyLabel`：EASY / CHAL / HARD）。
  final String? difficultyLabel;

  /// 服务端给的 CSS 配色类名（`DifficultyColor`），目前仅作留档，
  /// 手机端自己按 [difficulty] 取色。
  final String? difficultyColor;

  /// 服务端给的难度说明（`DifficultyDescription`），用于长按提示。
  final String? difficultyDescription;

  final List<int>? statusDistribution;
  final List<String>? tags;
  final String? lastRead;
  final bool isCompleted;
  final String? audioFilename;
  final bool audioMetadataResolved;
  final int? lastStatsRefresh;

  /// 服务端 `BookType` 字段（`''` / `'manga'` / `'series'` / …）。
  final String bookType;

  /// 聚合行的 tag 名；普通书的该字段为 null。
  final String? seriesTag;

  /// 聚合行包含的书数（只统计未归档的）。
  final int? seriesBookCount;

  /// 聚合行中「已读完」的书数。
  final int? seriesReadCount;

  /// 聚合行中统计缺失或过期的成员书 id。
  ///
  /// 被聚合隐藏的书不会作为独立行出现，客户端需要主动为这些 id 拉一次统计，
  /// 否则聚合行会一直显示 0 词。与网页版 `ajax_in_book_stats` 的行为一致。
  final List<int>? seriesStatsPending;

  /// 是否是 tag 聚合行。聚合行没有自己的 BkID，不能当普通书打开。
  bool get isSeries =>
      bookType == seriesBookType ||
      (seriesTag != null && seriesTag!.isNotEmpty);

  /// 聚合行代表的书数。服务端把书数放在 PageCount 里，这里优先用显式字段。
  int get seriesCount => seriesBookCount ?? totalPages;

  bool get hasStats => distinctTerms != null && statusDistribution != null;

  /// 是否有可展示的词数。
  ///
  /// 不能直接用 [hasStats]：聚合行的 `StatusDistribution` 恒为 NULL
  /// （服务端只聚合词数，不聚合状态分布），但它确实带了有效的
  /// `DistinctCount`，用 hasStats 判断会让聚合卡片显示「— terms」。
  bool get hasTermCount => distinctTerms != null;

  /// 难度百分比。服务端没给 NewWordPercent（旧版本 / 统计未跑）时用
  /// UnknownPercent 兜底，宁可近似也不要留空。
  double? get newWordPercentOrUnknown => newWordPercent ?? unknownPct;

  /// 是否已经算过新词比例。null 表示这本书还没跑过统计，卡片上要显示占位。
  bool get hasNewWordPercent => newWordPercentOrUnknown != null;

  /// 新词难度档位。
  ///
  /// 优先用服务端给的 `DifficultyLabel`（阈值在 lute/book/stats.py 单点维护），
  /// 服务端没给时才按百分比本地算，兜底阈值与服务端一致。
  BookDifficulty get difficulty =>
      BookDifficultyLevel.fromLabel(difficultyLabel) ??
      BookDifficultyLevel.fromPercent(newWordPercentOrUnknown);

  /// 难度说明文案：优先用服务端那份，避免中英文案漂移。
  String get difficultyHint =>
      (difficultyDescription != null && difficultyDescription!.isNotEmpty)
      ? difficultyDescription!
      : difficulty.description;

  bool get hasAudio => audioFilename != null && audioFilename!.isNotEmpty;
  bool get isStatsExpired {
    if (lastStatsRefresh == null) return true;
    final ttl = Duration(hours: 48);
    final now = DateTime.now().millisecondsSinceEpoch;
    final age = now - lastStatsRefresh!;
    return age > ttl.inMilliseconds;
  }

  Book({
    required this.id,
    required this.title,
    required this.language,
    this.langId,
    required this.totalPages,
    required this.currentPage,
    required this.percent,
    required this.wordCount,
    required this.distinctTerms,
    required this.unknownPct,
    required this.statusDistribution,
    this.unknownCount,
    this.newWordPercent,
    this.difficultyLabel,
    this.difficultyColor,
    this.difficultyDescription,
    this.tags,
    this.lastRead,
    this.isCompleted = false,
    this.audioFilename,
    this.audioMetadataResolved = false,
    this.lastStatsRefresh,
    this.bookType = '',
    this.seriesTag,
    this.seriesBookCount,
    this.seriesReadCount,
    this.seriesStatsPending,
  });

  String? get formattedLastRead {
    if (lastRead == null || lastRead!.isEmpty) return null;
    return _formatRelativeTime(lastRead!);
  }

  String? get formattedLastReadExact {
    if (lastRead == null || lastRead!.isEmpty) return null;
    try {
      final date = DateTime.parse(lastRead!).toLocal();
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
          '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
    } catch (e) {
      return lastRead;
    }
  }

  String _formatRelativeTime(String dateStr) {
    try {
      final now = DateTime.now();
      final date = DateTime.parse(dateStr).toLocal();
      final difference = now.difference(date);

      if (difference.inSeconds < 60) {
        return 'just now';
      } else if (difference.inMinutes < 60) {
        final mins = difference.inMinutes;
        return '$mins minute${mins != 1 ? "s" : ""} ago';
      } else if (difference.inHours < 24) {
        final hours = difference.inHours;
        return '$hours hour${hours != 1 ? "s" : ""} ago';
      } else if (difference.inDays < 7) {
        final days = difference.inDays;
        return '$days day${days != 1 ? "s" : ""} ago';
      } else if (difference.inDays < 30) {
        final weeks = (difference.inDays / 7).floor();
        return '$weeks week${weeks != 1 ? "s" : ""} ago';
      } else if (difference.inDays < 365) {
        final months = (difference.inDays / 30).floor();
        return '$months month${months != 1 ? "s" : ""} ago';
      } else {
        final years = (difference.inDays / 365).floor();
        return '$years year${years != 1 ? "s" : ""} ago';
      }
    } catch (e) {
      return '';
    }
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    // 容错取整。服务器可能对某些字段返回 null（例如尚未生成统计的书、
    // 或 PageNum/PageCount 的 SQL 表达式算出 NULL），
    // 原先的 `as int` 强转会让整页书架直接抛异常打不开。
    int asInt(dynamic v, [int fallback = 0]) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    final isCompleted = asInt(json['IsCompleted']) == 1;
    final distinctCount = json['DistinctCount'];
    final unknownCountRaw = json['UnknownCount'];
    final unknownPercent = json['UnknownPercent'];
    final newWordPercentRaw = json['NewWordPercent'];
    final difficultyLabel = _nullableString(json['DifficultyLabel']);
    final difficultyColor = _nullableString(json['DifficultyColor']);
    final difficultyDescription = _nullableString(json['DifficultyDescription']);
    final statusDist = json['StatusDistribution'];
    final tagList = json['TagList'];
    final lastOpened = json['LastOpenedDate'];
    final pageCount = asInt(json['PageCount']);
    final pageNum = asInt(json['PageNum']);
    final audioFilename =
        (json['audio_filename'] ??
                json['audioFilename'] ??
                json['AudioFilename'])
            as String?;
    final audioMetadataResolved =
        json['audioMetadataResolved'] as bool? ??
        (audioFilename != null && audioFilename.isNotEmpty);

    List<int>? parsedStatusDist;
    if (statusDist is String && statusDist.isNotEmpty && statusDist != 'null') {
      // Parse from server (JSON string format)
      parsedStatusDist = _parseStatusDist(statusDist);
    } else if (statusDist is List) {
      // Already a List (from cache)
      parsedStatusDist = statusDist.map((e) => e as int).toList();
    }

    List<String>? parsedTags;
    if (tagList is String && tagList.isNotEmpty && tagList != 'null') {
      parsedTags = tagList.split(',').map((t) => t.trim()).toList();
    }

    final bookType = (json['BookType'] as String?)?.trim() ?? '';
    final seriesTag = json['SeriesTag'] as String?;
    final seriesBookCount = json['SeriesBookCount'] == null
        ? null
        : asInt(json['SeriesBookCount']);
    final seriesReadCount = json['SeriesReadCount'] == null
        ? null
        : asInt(json['SeriesReadCount']);
    final seriesStatsPending = _parseIdList(json['SeriesStatsPending']);
    final isSeriesRow =
        bookType == seriesBookType ||
        (seriesTag != null && seriesTag.isNotEmpty);

    // 聚合行的 PageNum/PageCount 是「已读书数 / 总书数」，不是页码，
    // 直接套用页数公式会得到 1/N 这种荒唐进度，所以改用服务端语义。
    final percent = isSeriesRow
        ? _seriesPercent(seriesReadCount, seriesBookCount ?? pageCount)
        : (pageCount > 0 ? ((pageNum / pageCount) * 100).round() : 0);

    return Book(
      id: asInt(json['BkID']),
      title: json['BkTitle'] as String? ?? '',
      language: json['LgName'] as String? ?? '',
      langId: (json['LgID'] as num?)?.toInt(),
      totalPages: pageCount,
      currentPage: pageNum,
      percent: percent,
      wordCount: asInt(json['WordCount']),
      distinctTerms: (distinctCount is int) ? distinctCount : null,
      unknownPct: (unknownPercent is num) ? unknownPercent.toDouble() : null,
      statusDistribution: parsedStatusDist,
      unknownCount: (unknownCountRaw is int)
          ? unknownCountRaw
          : (unknownCountRaw is num ? unknownCountRaw.toInt() : null),
      newWordPercent: (newWordPercentRaw is num)
          ? newWordPercentRaw.toDouble()
          : (newWordPercentRaw is String
                ? double.tryParse(newWordPercentRaw)
                : null),
      difficultyLabel: difficultyLabel,
      difficultyColor: difficultyColor,
      difficultyDescription: difficultyDescription,
      tags: parsedTags,
      lastRead: (lastOpened is String && lastOpened.isNotEmpty)
          ? lastOpened
          : null,
      isCompleted: isCompleted,
      audioFilename: audioFilename,
      audioMetadataResolved: audioMetadataResolved,
      lastStatsRefresh: json['lastStatsRefresh'] as int?,
      bookType: bookType,
      seriesTag: seriesTag,
      seriesBookCount: seriesBookCount,
      seriesReadCount: seriesReadCount,
      seriesStatsPending: seriesStatsPending,
    );
  }

  /// 空串（服务端给 NULL 时序列化出来的）统一当成 null。
  static String? _nullableString(dynamic v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  /// 聚合行的完成度 = 已读书数 / 总书数，四舍五入到整数百分比。
  static int _seriesPercent(int? readCount, int bookCount) {
    if (bookCount <= 0) return 0;
    final read = readCount ?? 0;
    return ((read * 100) / bookCount).round().clamp(0, 100);
  }

  /// 解析服务端用逗号拼接的 id 列表（如 `SeriesStatsPending = "3,7,12"`）。
  static List<int>? _parseIdList(dynamic raw) {
    if (raw is List) {
      final ids = raw
          .map((e) => e is int ? e : int.tryParse(e.toString()))
          .whereType<int>()
          .toList();
      return ids.isEmpty ? null : ids;
    }
    if (raw is String && raw.isNotEmpty && raw != 'null') {
      final ids = raw
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
      return ids.isEmpty ? null : ids;
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'BkID': id,
      'BkTitle': title,
      'LgName': language,
      'LgID': langId,
      'PageCount': totalPages,
      'PageNum': currentPage,
      'WordCount': wordCount,
      'DistinctCount': distinctTerms,
      'UnknownCount': unknownCount,
      'UnknownPercent': unknownPct,
      'NewWordPercent': newWordPercent,
      'DifficultyLabel': difficultyLabel,
      'DifficultyColor': difficultyColor,
      'DifficultyDescription': difficultyDescription,
      'StatusDistribution': statusDistribution,
      'IsCompleted': isCompleted ? 1 : 0,
      'audio_filename': audioFilename,
      'audioMetadataResolved': audioMetadataResolved,
      'LastOpenedDate': lastRead,
      'lastStatsRefresh': lastStatsRefresh,
      'TagList': tags,
      // 聚合行字段也要落缓存，否则读回来 isSeries 变成 false，
      // BkID=0 的聚合行会被当成「幽灵书」重新出现在书架上。
      'BookType': bookType,
      'SeriesTag': seriesTag,
      'SeriesBookCount': seriesBookCount,
      'SeriesReadCount': seriesReadCount,
      'SeriesStatsPending': seriesStatsPending,
    };
  }

  static List<int> _parseStatusDist(String dist) {
    if (dist.isEmpty || dist == 'null') {
      return List.generate(7, (i) => 0);
    }

    try {
      final dynamic parsed = jsonDecode(dist);
      if (parsed is! Map<String, dynamic>) {
        return List.generate(7, (i) => 0);
      }
      return [
        _getInt(parsed, '0'),
        _getInt(parsed, '1'),
        _getInt(parsed, '2'),
        _getInt(parsed, '3'),
        _getInt(parsed, '4'),
        _getInt(parsed, '5'),
        _getInt(parsed, '98'),
        _getInt(parsed, '99'),
      ];
    } catch (e) {
      return List.generate(7, (i) => 0);
    }
  }

  static int _getInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is int) {
      return value;
    }
    return 0;
  }

  /// 书架卡片右侧的进度徽标。聚合行显示「已读/总书数」而不是页码。
  String get pageProgress => isSeries
      ? '${seriesReadCount ?? 0}/$seriesCount books'
      : '$currentPage/$totalPages';

  Book copyWith({
    int? id,
    String? title,
    String? language,
    int? langId,
    int? totalPages,
    int? currentPage,
    int? percent,
    int? wordCount,
    int? distinctTerms,
    double? unknownPct,
    List<int>? statusDistribution,
    int? unknownCount,
    double? newWordPercent,
    String? difficultyLabel,
    String? difficultyColor,
    String? difficultyDescription,
    List<String>? tags,
    String? lastRead,
    bool? isCompleted,
    String? audioFilename,
    bool? audioMetadataResolved,
    int? lastStatsRefresh,
    String? bookType,
    String? seriesTag,
    int? seriesBookCount,
    int? seriesReadCount,
    List<int>? seriesStatsPending,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      language: language ?? this.language,
      langId: langId ?? this.langId,
      totalPages: totalPages ?? this.totalPages,
      currentPage: currentPage ?? this.currentPage,
      percent: percent ?? this.percent,
      wordCount: wordCount ?? this.wordCount,
      distinctTerms: distinctTerms ?? this.distinctTerms,
      unknownPct: unknownPct ?? this.unknownPct,
      statusDistribution: statusDistribution ?? this.statusDistribution,
      unknownCount: unknownCount ?? this.unknownCount,
      newWordPercent: newWordPercent ?? this.newWordPercent,
      difficultyLabel: difficultyLabel ?? this.difficultyLabel,
      difficultyColor: difficultyColor ?? this.difficultyColor,
      difficultyDescription:
          difficultyDescription ?? this.difficultyDescription,
      tags: tags ?? this.tags,
      lastRead: lastRead ?? this.lastRead,
      isCompleted: isCompleted ?? this.isCompleted,
      audioFilename: audioFilename ?? this.audioFilename,
      audioMetadataResolved:
          audioMetadataResolved ?? this.audioMetadataResolved,
      lastStatsRefresh: lastStatsRefresh ?? this.lastStatsRefresh,
      bookType: bookType ?? this.bookType,
      seriesTag: seriesTag ?? this.seriesTag,
      seriesBookCount: seriesBookCount ?? this.seriesBookCount,
      seriesReadCount: seriesReadCount ?? this.seriesReadCount,
      seriesStatsPending: seriesStatsPending ?? this.seriesStatsPending,
    );
  }
}
