import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/book_type_icons.dart';
import '../../../shared/utils/language_flag_mapper.dart';
import '../../../shared/widgets/new_word_difficulty_badge.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/book.dart';

/// 书架上的单条卡片。
///
/// 有两种形态：普通书（点开进 Reader）与 Book Set 聚合行
/// （`book.isSeries`，点开进系列列表页，见 SeriesDetailScreen）。
class BookCard extends ConsumerWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displaySettings = ref.watch(bookDisplaySettingsProvider);
    final isSeries = book.isSeries;
    final typeIcon = BookTypeIcons.of(book.bookType, isSeries: isSeries);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 书籍类型图标（text / manga / youtube / mp3 / …）。
                  // 配色取自服务端 lute/book/types.py 的同一份注册表。
                  //
                  // 这里只留类型图标：原先并排的「TTS 小喇叭」（book.hasAudio）
                  // 与「阅读完成」（book.isCompleted）已去掉 —— 右侧的
                  // pageProgress 徽标已经把完成度说清楚，喇叭又和 mp3 类型图标
                  // 语义重叠，三个图标挤在标题左边只会把标题推窄。
                  Tooltip(
                    message: typeIcon.label,
                    child: Icon(typeIcon.icon, size: 20, color: typeIcon.color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      book.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.appColorScheme.background.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      book.pageProgress,
                      style: TextStyle(
                        color: context.appColorScheme.text.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              // 聚合行的 tags 就是 tag 名本身，与标题重复，不再展示。
              if (!isSeries &&
                  book.tags != null &&
                  book.tags!.isNotEmpty &&
                  displaySettings.showTags)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: book.tags!
                        .map(
                          (tag) => Chip(
                            label: Text(tag),
                            labelPadding: EdgeInsets.zero,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            backgroundColor:
                                context.appColorScheme.background.surface,
                          ),
                        )
                        .toList(),
                  ),
                ),
              const SizedBox(height: 8),
              // 用 Wrap 而不是 Row：聚合行多了一个「Book Set · N」标签，
              // 定长 Row 会把右侧的词数/词条挤出屏幕（真机上表现为被裁切）。
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        getFlagForLanguage(book.language) ?? '🌐',
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        book.language,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.appColorScheme.text.secondary,
                        ),
                      ),
                    ],
                  ),
                  if (isSeries)
                    _SeriesBadge(label: 'Book Set · ${book.seriesCount}'),
                  Text(
                    '${book.wordCount} words',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    book.hasTermCount ? '${book.distinctTerms} terms' : '— terms',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (displaySettings.showLastRead)
                Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 14,
                      color: context.appColorScheme.text.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      book.formattedLastRead ?? 'Never',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.appColorScheme.text.secondary,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              // 新词难度（EASY / CHAL / HARD），取代原来的状态分布条。
              // 聚合行服务端也算好了 NewWordPercent（成员书的平均），
              // 所以这里两种卡片用同一套渲染。
              NewWordDifficultyBadge(book: book),
              // 聚合行另外画一条「已读/总书数」，因为右侧徽标只有数字。
              if (isSeries) ...[
                const SizedBox(height: 8),
                _SeriesProgressBar(book: book),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「Book Set」小标签，提示这张卡片点开是列表而不是正文。
class _SeriesBadge extends StatelessWidget {
  final String label;

  const _SeriesBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors.background.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.text.secondary,
        ),
      ),
    );
  }
}

/// 聚合行的阅读进度条：已读书数 / 总书数。
class _SeriesProgressBar extends StatelessWidget {
  final Book book;

  const _SeriesProgressBar({required this.book});

  @override
  Widget build(BuildContext context) {
    final total = book.seriesCount;
    final read = book.seriesReadCount ?? 0;
    final value = total <= 0 ? 0.0 : (read / total).clamp(0.0, 1.0);

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor:
                  context.appColorScheme.background.surfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$read/$total read',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.appColorScheme.text.secondary,
          ),
        ),
      ],
    );
  }
}
