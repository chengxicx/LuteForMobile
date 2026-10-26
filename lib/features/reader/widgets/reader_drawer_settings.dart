import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/features/settings/providers/settings_provider.dart';
import 'package:song_mobile/features/settings/widgets/text_formatting_controls.dart';
import 'package:song_mobile/core/cache/providers/tooltip_cache_provider.dart';
import 'package:song_mobile/core/cache/providers/cache_stats_provider.dart';
import 'package:song_mobile/shared/theme/theme_extensions.dart';
import '../providers/sentence_reader_provider.dart';
import '../providers/reader_provider.dart';
import '../models/page_data.dart';
import '../../../../app.dart';

class ReaderDrawerSettings extends ConsumerWidget {
  final String currentRoute;

  const ReaderDrawerSettings({super.key, required this.currentRoute});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final termFormSettings = ref.watch(termFormSettingsProvider);

    // 阅读抽屉的信息层级：最高频的排版调节置顶且不再折叠（折叠的
    // ExpansionTile 曾把字号控件整个藏起来，字体字号根本调不了），阅读开关
    // 随后；Word Glow、Tooltip 图片、缓存维护这些设一次就不动的低频项沉到
    // 底部 More Options。所有选项都留在本抽屉内，不迁全局 Settings。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(context, 'Text Formatting'),
          const SizedBox(height: 8),
          // The preview shows the page being read -- sizing text against a
          // fixed Latin sample would be wrong for a Chinese or Arabic book,
          // and the panel covers the page it is meant to be judging.
          Consumer(
            builder: (context, ref, _) {
              final pageData = ref.watch(
                readerProvider.select((s) => s.pageData),
              );
              return TextFormattingControls(
                dense: true,
                previewTokens: _previewTokens(pageData),
              );
            },
          ),
          const SizedBox(height: 16),
          _buildFullscreenToggle(context, ref),
          if (currentRoute != 'sentence-reader') ...[
            const SizedBox(height: 16),
            _buildPageNumbersToggle(context, ref, settings),
            const SizedBox(height: 16),
            _buildFuriganaToggle(context, ref, settings),
            const SizedBox(height: 16),
            _buildEpubLookSelector(),
          ],
          const SizedBox(height: 16),
          // 播放条总开关：以前只在有声书（有 MP3）上出现，纯文本书只有朗读
          // 条、反而没有关掉它的入口。现在这是"所有播放条"的总开关 —— MP3
          // 条和 TTS 条都看 settings.showAudioPlayer。
          Consumer(
            builder: (context, ref, _) {
              final pageData = ref.watch(
                readerProvider.select((s) => s.pageData),
              );
              if (pageData != null &&
                  (pageData.isManga ||
                      pageData.isPdf ||
                      pageData.isVideoBook)) {
                return const SizedBox.shrink();
              }
              return _buildPlayerToggle(context, ref, settings);
            },
          ),
          const SizedBox(height: 24),
          // 句读入口 / 错误面板：出错时就地显示，保持原有行为。
          Consumer(
            builder: (context, ref, _) {
              final error = ref.watch(sentenceReaderProvider).errorMessage;

              if (error != null) {
                return Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: context.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.error_outline, color: context.error),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Sentence Reader Error',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: context.error,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  ref
                                      .read(sentenceReaderProvider.notifier)
                                      .clearError();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () async {
                                    final reader = ref.read(readerProvider);
                                    if (reader.pageData != null) {
                                      await ref
                                          .read(sentenceReaderProvider.notifier)
                                          .parseSentencesForPage(
                                            _getLangId(reader),
                                            initialIndex: 0,
                                          );
                                    }
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry'),
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size(
                                      double.infinity,
                                      36,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await ref
                            .read(sentenceReaderProvider.notifier)
                            .triggerFlushAndRebuild();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Cache flushed and rebuilt!'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.view_headline),
                      label: const Text('Flush Cache & Rebuild'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text(
                          'Show Known Terms',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.showKnownTermsInSentenceReader,
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateShowKnownTermsInSentenceReader(value);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              }

              return Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      if (currentRoute == 'sentence-reader') {
                        await ref
                            .read(sentenceReaderProvider.notifier)
                            .triggerFlushAndRebuild();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Cache flushed and rebuilt!'),
                            ),
                          );
                        }
                      } else {
                        ref.read(navigationProvider).navigateToScreen('reader');
                        Future.microtask(
                          () => ref
                              .read(navigationProvider)
                              .navigateToScreen('sentence-reader'),
                        );
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.view_headline),
                    label: currentRoute == 'sentence-reader'
                        ? const Text('Flush Cache & Rebuild')
                        : const Text('Open Sentence Reader'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (currentRoute == 'sentence-reader')
                    Row(
                      children: [
                        const Text(
                          'Show Known Terms',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.showKnownTermsInSentenceReader,
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateShowKnownTermsInSentenceReader(value);
                            },
                          ),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          _sectionLabel(context, 'More Options'),
          const SizedBox(height: 8),
          if (currentRoute != 'sentence-reader') ...[
            _buildWordGlowToggle(context, ref),
            const SizedBox(height: 16),
          ],
          _buildTooltipImagesToggle(context, ref, termFormSettings),
          const SizedBox(height: 24),
          Consumer(
            builder: (context, ref, _) {
              // Refresh cache stats when this section is built
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ref.invalidate(cacheStatsProvider);
              });

              return Column(
                  children: [
                    Consumer(
                      builder: (context, ref, _) {
                        final cacheStats = ref.watch(cacheStatsProvider);

                        return cacheStats.when(
                          data: (stats) {
                            int cacheCount = stats['validEntries'] ?? 0;

                            return OutlinedButton.icon(
                              onPressed: () async {
                                // Get the tooltip cache service
                                final tooltipCacheService = ref.read(
                                  tooltipCacheServiceProvider,
                                );

                                // Clear the cache
                                final success = await tooltipCacheService
                                    .clearAllCache();

                                if (success && context.mounted) {
                                  // Refresh the cache stats after clearing
                                  ref.invalidate(cacheStatsProvider);

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Tooltip cache cleared successfully',
                                      ),
                                    ),
                                  );
                                } else if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Failed to clear tooltip cache',
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.refresh),
                              label: Text(
                                'Refresh Tooltip Cache ($cacheCount)',
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(double.infinity, 40),
                              ),
                            );
                          },
                          loading: () => OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.refresh),
                            label: const Text(
                              'Refresh Tooltip Cache (Loading...)',
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 40),
                            ),
                          ),
                          error: (error, stack) => OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh Tooltip Cache (Error)'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 40),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 分区小标题：titleMedium 与抽屉 header 同级；之前 ExpansionTile 的
  /// titleLarge（22sp）在 320px 宽的抽屉里过于突兀。
  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildFullscreenToggle(BuildContext context, WidgetRef ref) {
    final fullscreenMode = ref.watch(
      textFormattingSettingsProvider.select((s) => s.fullscreenMode),
    );
    return Row(
      children: [
        const Text(
          'Fullscreen Mode',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: fullscreenMode,
            onChanged: (value) {
              ref
                  .read(textFormattingSettingsProvider.notifier)
                  .updateFullscreenMode(value);
            },
          ),
        ),
      ],
    );
  }

  /// 播放条总开关（MP3 条 / TTS 朗读条共用）。
  ///
  /// 开关是"显示"语义：关掉 = 全部播放条都不出现（正在播的 MP3 会重置、
  /// 朗读条停止装配），书照常读，句子高亮也跟着停。
  Widget _buildPlayerToggle(
    BuildContext context,
    WidgetRef ref,
    dynamic settings,
  ) {
    return Row(
      children: [
        const Text(
          'Show Player',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: settings.showAudioPlayer,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateShowAudioPlayer(value);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWordGlowToggle(BuildContext context, WidgetRef ref) {
    final termFormSettings = ref.watch(termFormSettingsProvider);
    return Row(
      children: [
        const Text('Word Glow', style: TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: termFormSettings.wordGlowEnabled,
            onChanged: (value) {
              ref
                  .read(termFormSettingsProvider.notifier)
                  .updateWordGlowEnabled(value);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTooltipImagesToggle(
    BuildContext context,
    WidgetRef ref,
    TermFormSettings termFormSettings,
  ) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Show Tooltip Images',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: termFormSettings.showTooltipImages,
            onChanged: (value) {
              ref
                  .read(termFormSettingsProvider.notifier)
                  .updateShowTooltipImages(value);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPageNumbersToggle(
    BuildContext context,
    WidgetRef ref,
    dynamic settings,
  ) {
    return Row(
      children: [
        const Text(
          'Show Page Numbers',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: settings.showPageNumbers,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateShowPageNumbers(value);
            },
          ),
        ),
      ],
    );
  }

  /// 正文注音开关。这是 App 自己的开关，与 web 端语言设置里的
  /// 「Show furigana above words」相互独立。
  Widget _buildFuriganaToggle(
    BuildContext context,
    WidgetRef ref,
    dynamic settings,
  ) {
    return Row(
      children: [
        const Text(
          'Show Furigana',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: settings.furiganaEnabled,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).updateFuriganaEnabled(value);
            },
          ),
        ),
      ],
    );
  }

  /// Reader-mode EPUB 书的外观选择（原书 / 夜间 / 跟随主题），对应 web 端
  /// 阅读菜单的三个外观。只在正在读 epub 书时出现；选择存本机（与 web 端
  /// 互不同步），EpubChapterView 监听设置变化即时推给页内。
  Widget _buildEpubLookSelector() {
    return Consumer(
      builder: (context, ref, _) {
        final isEpub = ref.watch(
          readerProvider.select((s) => s.pageData?.epubChapter != null),
        );
        if (!isEpub) return const SizedBox.shrink();
        final look = ref.watch(
          settingsProvider.select((s) => s.epubLookMode),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'EPUB Look',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final mode in const [
                  ('original', 'Original'),
                  ('night', 'Night'),
                  ('theme', 'Theme'),
                ])
                  ChoiceChip(
                    label: Text(mode.$2),
                    selected: look == mode.$1,
                    onSelected: (_) {
                      ref
                          .read(settingsProvider.notifier)
                          .updateEpubLookMode(mode.$1);
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// The first stretch of the page being read, for the formatting preview.
  ///
  /// Statuses come along so the term colours are judged at the same time as
  /// the size -- a status patch that is legible at 20px can swallow the text
  /// at 14px.  Items without a wordId (spacing between words) are plain.
  List<PreviewToken>? _previewTokens(PageData? pageData) {
    final paragraphs = pageData?.paragraphs;
    if (paragraphs == null || paragraphs.isEmpty) return null;
    return paragraphs.first.textItems.take(16).map((item) {
      final match = RegExp(r'status(\d+)').firstMatch(item.statusClass);
      return (
        text: item.text,
        status: item.wordId == null ? null : match?.group(1) ?? '0',
      );
    }).toList();
  }

  int _getLangId(ReaderState reader) {
    if (reader.pageData?.paragraphs.isNotEmpty == true &&
        reader.pageData!.paragraphs[0].textItems.isNotEmpty) {
      return reader.pageData!.paragraphs[0].textItems.first.langId ?? 0;
    }
    return 0;
  }
}
