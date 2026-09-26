import 'package:flutter/material.dart';
import 'package:song_mobile/features/books/models/book.dart';
import 'package:song_mobile/features/books/models/book_difficulty.dart';
import 'package:song_mobile/shared/theme/eink.dart';
import 'package:song_mobile/shared/theme/theme_extensions.dart';

/// 书架卡片上的「新词难度」徽标。
///
/// 取代原来的状态分布条（StatusDistributionBar）：那条画的是
/// unknown/learning/known 的词数占比，看不出这本书读起来难不难；
/// 这里只显示服务端按 new-word 百分比算好的难度档位
/// （EASY / CHAL / HARD，阈值见 [BookDifficultyLevel]），
/// 与 web 端 `render_new_word` 徽标同一套口径。
///
/// 卡片上不画进度条：档位 + 百分比已经说明问题，再加一条 bar 只是重复信息。
class NewWordDifficultyBadge extends StatelessWidget {
  final Book book;

  /// 是否在徽标后面补一行「N new words」。
  final bool showNewWordCount;

  const NewWordDifficultyBadge({
    super.key,
    required this.book,
    this.showNewWordCount = true,
  });

  /// 档位配色，与 web 端 styles.css 的 .new-word-* 一致。
  static Color background(BookDifficulty level) {
    switch (level) {
      case BookDifficulty.easy:
        return const Color(0xFF72DA88);
      case BookDifficulty.challenging:
        return const Color(0xFFFFD43B);
      case BookDifficulty.hard:
        return const Color(0xFFFF6B6B);
    }
  }

  static Color foreground(BookDifficulty level) {
    switch (level) {
      case BookDifficulty.easy:
        return const Color(0xFF1A5F2A);
      case BookDifficulty.challenging:
        return const Color(0xFF7A6000);
      case BookDifficulty.hard:
        return const Color(0xFF8B1A1A);
    }
  }

  /// 墨水屏配色：彩底彩字在 16 灰阶里挤成一团（绿/黄/红底亮度接近，
  /// 深彩字与底几乎同灰度）。改用「底色深浅 + 字色反差」表达档位：
  /// 浅色主题 EASY 最浅、HARD 最深字用白；深色主题反向。
  static (Color, Color) einkColors(BookDifficulty level, bool dark) {
    switch (level) {
      case BookDifficulty.easy:
        return dark
            ? (const Color(0xFF2E2E2E), Colors.white)
            : (const Color(0xFFE8E8E8), Colors.black);
      case BookDifficulty.challenging:
        return dark
            ? (const Color(0xFF565656), Colors.white)
            : (const Color(0xFFB4B4B4), Colors.black);
      case BookDifficulty.hard:
        return dark
            ? (const Color(0xFFB4B4B4), Colors.black)
            : (const Color(0xFF3A3A3A), Colors.white);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;

    // 还没跑过统计：给一个中性占位，别显示成 EASY（会被误读成「很简单」）。
    if (!book.hasNewWordPercent) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.background.surfaceVariant,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '—',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.text.secondary),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Difficulty unknown — stats not calculated yet',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.text.secondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    final level = book.difficulty;
    final pct = (book.newWordPercentOrUnknown ?? 0).clamp(0.0, 100.0);

    final eink = context.eInk;
    final (badgeBg, badgeFg) = eink
        ? einkColors(level, Theme.of(context).brightness == Brightness.dark)
        : (background(level), foreground(level));

    final badge = Tooltip(
      message: book.difficultyHint,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: badgeBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${level.label} ${pct.round()}%',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: badgeFg,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    if (!showNewWordCount || book.unknownCount == null) return badge;

    return Row(
      children: [
        badge,
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${_formatCount(book.unknownCount!)} new words'
            '${book.distinctTerms != null ? ' of ${_formatCount(book.distinctTerms!)}' : ''}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.text.secondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  static String _formatCount(int n) {
    final s = n.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }
}
