import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/audio_cache_service.dart';
import '../../../core/cache/providers/audio_cache_provider.dart';
import '../../../core/cache/providers/cache_manager_provider.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../books/providers/books_provider.dart';
import '../../reader/providers/audio_player_provider.dart';

/// 把字节数写成用户看得懂的量级。
String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 设置页的「Storage & Cache」分区。
///
/// **刻意不做「一键全清」**：缓存里有两类性质完全不同的东西 ——
/// 页面/词条缓存可再生、体积小，清掉只是下次打开重新拉一次；音频缓存是
/// 离线播放与影子跟读的根基，一本 6–64MB，清掉就是重新走一遍流量。混在
/// 一个按钮里，用户为了刷新一个页面就会顺手把几十 MB 的有声书删掉。
///
/// 因此两个独立入口：页面/词条缓存是普通按钮，音频缓存单独一行、显示占用
/// 体积与本数，确认框写明"要重新下载、会消耗流量"。
class StorageCacheSection extends ConsumerStatefulWidget {
  const StorageCacheSection({super.key});

  @override
  ConsumerState<StorageCacheSection> createState() =>
      _StorageCacheSectionState();
}

class _StorageCacheSectionState extends ConsumerState<StorageCacheSection> {
  int? _pageBytes;
  AudioCacheStats? _audioStats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// 读一遍两类缓存的占用。
  ///
  /// 读之前先回收一次音频孤儿：卡片上的数字要反映"真正占了多少"，否则用户
  /// 看到 900MB、点清理却只删掉 200MB，这个数就再也没人信了。书架为空
  /// （还没加载出来）时**不传** knownBookIds —— 那会被当成"什么书都没有"，
  /// 把用户的离线音频全删掉。
  Future<void> _refresh() async {
    final books = ref.read(booksProvider);
    final shelfIds = <int>{
      for (final book in books.activeBooks)
        if (!book.isSeries) book.id,
      for (final book in books.archivedBooks)
        if (!book.isSeries) book.id,
    };

    await ref
        .read(audioCacheServiceProvider)
        .collectOrphans(knownBookIds: shelfIds.isEmpty ? null : shelfIds);

    final pageBytes = await ref.read(cacheManagerProvider).getPageCacheBytes();
    final audio = await ref.read(audioCacheServiceProvider).getStats();
    if (!mounted) return;
    setState(() {
      _pageBytes = pageBytes;
      _audioStats = audio;
    });
  }

  Future<void> _clearPageCaches() async {
    final confirmed = await _confirm(
      title: 'Clear page & term cache',
      message:
          'Pages, sentences, terms and tooltips will be fetched again the next '
          'time you open them. Reading progress and bookmarks live on the '
          'server, so they are not affected.',
      confirmLabel: 'Clear',
    );
    if (confirmed != true || !mounted) return;
    await _run(() => ref.read(cacheManagerProvider).clearPageCaches());
  }

  Future<void> _clearAudioCache() async {
    final stats = _audioStats;
    final detail = stats == null || stats.isEmpty
        ? ''
        : '${stats.bookCount} cached book(s), ${formatCacheBytes(stats.bytes)}. ';
    final confirmed = await _confirm(
      title: 'Clear audio cache',
      message:
          '${detail}They must be downloaded again the next time you play them, '
          'which uses mobile data. Offline playback and shadowing stop working '
          'until then.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    // 先卸掉播放器手里的音源：清完文件它还在引用那个路径，再按播放就是一个
    // 已被删除的文件。
    ref.read(audioPlayerProvider.notifier).reset();
    await _run(() => ref.read(cacheManagerProvider).clearAudioCache());
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to clear cache: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: dialogContext.error)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final audio = _audioStats;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Storage & Cache',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Caches rebuild themselves; clearing one only costs a re-download. '
              'Audio files are what offline playback and shadowing read from.',
              style: TextStyle(
                fontSize: 12,
                color: context.appColorScheme.text.secondary,
              ),
            ),
            const SizedBox(height: 16),
            _buildEntry(
              context,
              title: 'Pages, sentences & terms',
              subtitle: 'Rebuilt the next time you open a book',
              size: _pageBytes == null ? '…' : formatCacheBytes(_pageBytes!),
              onClear: _busy ? null : _clearPageCaches,
            ),
            const Divider(height: 24),
            _buildEntry(
              context,
              title: 'Audio',
              subtitle: audio == null
                  ? 'Measuring…'
                  : '${audio.bookCount} book(s) cached · offline playback & '
                        'shadowing',
              size: audio == null ? '…' : formatCacheBytes(audio.bytes),
              onClear: _busy ? null : _clearAudioCache,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String size,
    required VoidCallback? onClear,
  }) {
    final textColors = context.appColorScheme.text;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: textColors.secondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 数字用主文字色，不用次级灰：墨水屏上灰字压在浅底上几乎看不见，
        // 而这个数正是用户点"Clear"之前唯一要看的东西。
        Text(
          size,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: textColors.primary,
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(foregroundColor: context.error),
          child: const Text('Clear'),
        ),
      ],
    );
  }
}
