/// 书籍的「新词难度」分档。
///
/// 阈值与服务端 `lute/book/stats.py` 的 `NEW_WORD_EASY_PERCENT` /
/// `NEW_WORD_CHAL_PERCENT` 保持一致：
///   * easy:        new_word_percent < 10
///   * challenging: 10 <= new_word_percent <= 20
///   * hard:        new_word_percent > 20
///
/// 服务端已经在 SQL 里算好了 `DifficultyLabel`，客户端优先用它；
/// 只有服务端没给（旧版本 / 统计还没跑）时才按百分比本地兜底，
/// 这样两边永远不会显示不一致的档位。
enum BookDifficulty { easy, challenging, hard }

/// 与 [BookDifficulty] 配套的阈值、标签与文案。
class BookDifficultyLevel {
  /// EASY 与 CHAL 的分界（百分比，不含）。
  static const int easyPercent = 10;

  /// CHAL 与 HARD 的分界（百分比，含）。
  static const int chalPercent = 20;

  static const String easyLabel = 'EASY';
  static const String challengingLabel = 'CHAL';
  static const String hardLabel = 'HARD';

  /// 服务端 `DifficultyLabel` → 枚举。无法识别时返回 null（交给百分比兜底）。
  static BookDifficulty? fromLabel(String? label) {
    switch (label?.trim().toUpperCase()) {
      case easyLabel:
        return BookDifficulty.easy;
      case challengingLabel:
        return BookDifficulty.challenging;
      case hardLabel:
        return BookDifficulty.hard;
      default:
        return null;
    }
  }

  /// 新词百分比 → 枚举。null（还没统计）按服务端口径算 EASY。
  static BookDifficulty fromPercent(double? percent) {
    if (percent == null || percent.isNaN) return BookDifficulty.easy;
    if (percent < easyPercent) return BookDifficulty.easy;
    if (percent <= chalPercent) return BookDifficulty.challenging;
    return BookDifficulty.hard;
  }
}

extension BookDifficultyX on BookDifficulty {
  /// 与 web 端 `render_new_word` 徽标一致的短标签。
  String get label {
    switch (this) {
      case BookDifficulty.easy:
        return BookDifficultyLevel.easyLabel;
      case BookDifficulty.challenging:
        return BookDifficultyLevel.challengingLabel;
      case BookDifficulty.hard:
        return BookDifficultyLevel.hardLabel;
    }
  }

  /// 长按徽标时的解释文案（服务端也会给一份，缺省时用这个）。
  String get description {
    final easy = BookDifficultyLevel.easyPercent;
    final chal = BookDifficultyLevel.chalPercent;
    switch (this) {
      case BookDifficulty.easy:
        return 'Easy: under $easy% of words are new.';
      case BookDifficulty.challenging:
        return 'Challenging: $easy-$chal% of words are new.';
      case BookDifficulty.hard:
        return 'Hard: over $chal% of words are new.';
    }
  }
}
