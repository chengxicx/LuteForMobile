import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/content_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/language_flag_mapper.dart';
import '../../../shared/providers/network_providers.dart';
import '../../reader/services/book_offline_service.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/book.dart';
import '../providers/books_provider.dart';
import 'edit_book_dialog.dart';

import 'package:song_mobile/app.dart';

class BookDetailsDialog extends ConsumerStatefulWidget {
  final Book book;
  final bool isArchived;

  const BookDetailsDialog({
    super.key,
    required this.book,
    this.isArchived = false,
  });

  @override
  ConsumerState<BookDetailsDialog> createState() => _BookDetailsDialogState();
}

class _BookDetailsDialogState extends ConsumerState<BookDetailsDialog> {
  late Book _displayBook;
  bool _isRefreshingStats = false;

  // ---- offline state (all book types) ----
  BookOfflineStatus? _offline;
  bool _offlineKnown = false;
  BookOfflineTask? _task;

  /// Resolved once in initState: `ref.read` is not reliable in dispose.
  BookOfflineService? _service;

  BookOfflineService get _offlineService {
    final cached = _service;
    if (cached != null) return cached;
    final resolved = ref.read(bookOfflineServiceProvider);
    _service = resolved;
    return resolved;
  }

  @override
  void initState() {
    super.initState();
    _displayBook = widget.book;
    final settings = ref.read(settingsProvider);
    if (settings.alwaysRefreshBookDetails) {
      _refreshBookStatsInBackground(widget.book.id);
    }
    if (!_displayBook.isSeries) {
      _service = ref.read(bookOfflineServiceProvider);
      _service!.tasks.addListener(_handleTaskChange);
      _loadOfflineState();
    }
  }

  @override
  void dispose() {
    _service?.tasks.removeListener(_handleTaskChange);
    super.dispose();
  }

  void _handleTaskChange() {
    if (!mounted) return;
    final task = _offlineService.tasks.value[_displayBook.id];
    final wasRunning = _task?.running ?? false;
    setState(() => _task = task);
    if (task != null && !task.running && wasRunning) {
      _loadOfflineState();
    }
  }

  Future<void> _loadOfflineState() async {
    final status = await _offlineService.statusFor(_displayBook);
    if (!mounted) return;
    setState(() {
      _offline = status;
      _offlineKnown = true;
      _task = _offlineService.tasks.value[_displayBook.id];
    });
  }

  Future<void> _startOfflineDownload({bool forceRefresh = false}) async {
    try {
      await _offlineService.download(_displayBook, forceRefresh: forceRefresh);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Offline download failed: '
              '${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) await _loadOfflineState();
    }
  }

  Future<void> _deleteOffline() async {
    final confirmed = await _showConfirmDialog(
      context,
      'Delete Offline Copy',
      'Delete everything stored for "${_displayBook.title}" on this device? '
          'The book itself stays on the server.',
    );
    if (!confirmed || !mounted) return;
    await _offlineService.deleteOffline(_displayBook);
    await _loadOfflineState();
  }

  Future<void> _refreshBookStatsInBackground(int bookId) async {
    if (!mounted) return;
    setState(() {
      _isRefreshingStats = true;
    });

    try {
      final settings = ref.read(settingsProvider);
      final contentService = ref.read(contentServiceProvider);

      final statsBook = settings.experimentalBookDetailsFullStatsEndpoint
          ? await contentService.getBookStats(
              bookId,
              timeout: const Duration(seconds: 15),
              forceRecalc: true,
              fullBook: true,
            )
          : await _refreshBookStatsWithLegacyFlow(
              contentService,
              bookId,
              settings.stats500SampleSize,
              settings.statsCalcSampleSize,
            );

      final updatedBook = _displayBook.copyWith(
        distinctTerms: statsBook.distinctTerms,
        unknownPct: statsBook.unknownPct,
        statusDistribution: statsBook.statusDistribution,
        lastStatsRefresh: DateTime.now().millisecondsSinceEpoch,
      );

      await ref.read(booksProvider.notifier).updateBookInList(updatedBook);
      if (!mounted) return;
      setState(() {
        _displayBook = updatedBook;
      });
    } catch (e) {
      debugPrint('Book details stats refresh failed for bookId=$bookId: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingStats = false;
        });
      }
    }
  }

  Future<Book> _refreshBookStatsWithLegacyFlow(
    ContentService contentService,
    int bookId,
    int refreshSampleSize,
    int defaultSampleSize,
  ) async {
    await contentService.setUserSetting(
      'stats_calc_sample_size',
      refreshSampleSize.toString(),
      noQueue: true,
    );

    try {
      return await contentService.getBookStats(
        bookId,
        timeout: const Duration(seconds: 15),
      );
    } finally {
      await contentService.setUserSetting(
        'stats_calc_sample_size',
        defaultSampleSize.toString(),
        noQueue: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _displayBook;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      book.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () async {
                      final edited = await showDialog<bool>(
                        context: context,
                        builder: (_) => EditBookDialog(bookId: book.id),
                      );
                      if (edited == true && context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    icon: Icon(
                      widget.isArchived ? Icons.unarchive : Icons.archive,
                      size: 20,
                    ),
                    onPressed: () async {
                      final confirmed = await _showConfirmDialog(
                        context,
                        widget.isArchived ? 'Unarchive Book' : 'Archive Book',
                        'Are you sure you want to ${widget.isArchived ? "unarchive" : "archive"} "${book.title}"?',
                      );
                      if (confirmed && context.mounted) {
                        if (widget.isArchived) {
                          await ref
                              .read(booksProvider.notifier)
                              .unarchiveBook(book.id);
                        } else {
                          await ref
                              .read(booksProvider.notifier)
                              .archiveBook(book.id);
                        }
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                    tooltip: widget.isArchived ? 'Unarchive' : 'Archive',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    onPressed: () async {
                      final confirmed = await _showConfirmDialog(
                        context,
                        'Delete Book',
                        'Are you sure you want to delete "${book.title}"? This action cannot be undone.',
                      );
                      if (confirmed && context.mounted) {
                        await ref
                            .read(booksProvider.notifier)
                            .deleteBook(book.id);
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                    tooltip: 'Delete',
                    style: IconButton.styleFrom(foregroundColor: context.error),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    getFlagForLanguage(book.language) ?? '🌐',
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    book.language,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.appColorScheme.text.secondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildDetailRow(
                context,
                Icons.auto_stories,
                'Progress',
                '${book.pageProgress} (${book.percent}%)',
              ),
              const SizedBox(height: 12),
              _buildDetailRow(
                context,
                Icons.text_fields,
                'Total Words',
                book.wordCount.toString(),
              ),
              const SizedBox(height: 12),
              if (_isRefreshingStats) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 12),
              _buildDetailRow(
                context,
                Icons.list_alt,
                'Distinct Terms',
                book.distinctTerms?.toString() ?? '—',
              ),
              const SizedBox(height: 12),
              _buildDetailRow(
                context,
                Icons.help_outline,
                'Unknown Words',
                book.unknownPct != null
                    ? '${book.unknownPct!.toStringAsFixed(1)}%'
                    : '—',
              ),
              const SizedBox(height: 12),
              _buildDetailRow(
                context,
                Icons.access_time,
                'Last Read',
                book.formattedLastReadExact ?? 'Never',
              ),
              if (!book.isSeries) ...[
                const SizedBox(height: 12),
                _buildOfflineSection(context),
              ],
              if (book.tags != null && book.tags!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 0),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 2,
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
              ],
              if (book.hasStats) ...[
                const SizedBox(height: 24),
                Text(
                  'Status Distribution',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                _buildStatusDistributionDetails(
                  context,
                  book.statusDistribution!,
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      label: const Text('Close'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        // 必须把 Book 一起传下去：从 Book Set 页长按打开的成员书
                        // 不在书架列表里，app.dart 查不到它，不传就会退化成
                        // 一本没有标题、没有语言的空壳书。
                        ref
                            .read(navigationProvider)
                            .navigateToReader(book.id, null, book);
                        // 用 popUntil(isFirst) 而不是 pop()：本弹窗可能压在
                        // Book Set 页之上，只 pop 一层会把阅读器盖在下面。
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Reading'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Icon(icon, size: 20, color: context.appColorScheme.text.secondary),
        const SizedBox(width: 12),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.appColorScheme.text.secondary,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  /// Offline row for every book type.
  ///
  /// EPUB gets its chapter pack, text books and manga their page cache,
  /// PDF its file -- all pinned so the 14-day TTL / 100MB LRU cannot
  /// quietly take them away.  Audio (a separate 6-64MB download) is
  /// reported but not managed here.
  Widget _buildOfflineSection(BuildContext context) {
    if (!_offlineKnown) {
      return const LinearProgressIndicator(minHeight: 2);
    }

    final status = _offline;
    final task = _task;
    final secondary = status == null ? null : _audioLine(context, status);

    if (task != null && task.running) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_download,
                size: 20,
                color: context.appColorScheme.text.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _downloadingLabel(task),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () => _offlineService.cancel(_displayBook.id),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: task.fraction, minHeight: 2),
          if (secondary != null) ...[const SizedBox(height: 8), secondary],
        ],
      );
    }

    if (status == null || !status.hasAnything) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 20,
                color: context.appColorScheme.text.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Offline: not downloaded',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _startOfflineDownload,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download'),
              ),
            ],
          ),
          if (secondary != null) ...[const SizedBox(height: 8), secondary],
        ],
      );
    }

    final complete = status.isComplete;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              complete
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_download_outlined,
              size: 20,
              color: context.appColorScheme.text.secondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _offlineLabel(status),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  _startOfflineDownload(forceRefresh: status.isEpub),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Update'),
            ),
            TextButton.icon(
              onPressed: _deleteOffline,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
            ),
          ],
        ),
        if (secondary != null) ...[const SizedBox(height: 8), secondary],
      ],
    );
  }

  Widget? _audioLine(BuildContext context, BookOfflineStatus status) {
    if (status.audioBytes <= 0) return null;
    return Row(
      children: [
        Icon(
          Icons.headphones,
          size: 16,
          color: context.appColorScheme.text.secondary,
        ),
        const SizedBox(width: 12),
        Text(
          'Audio cached: ${_formatBytes(status.audioBytes)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.appColorScheme.text.secondary,
          ),
        ),
      ],
    );
  }

  String _offlineLabel(BookOfflineStatus status) {
    final incomplete = status.isComplete ? '' : ' (incomplete)';
    if (status.isPdf) {
      return 'Offline: ${_formatBytes(status.pdfBytes)}';
    }
    if (status.isEpub) {
      return 'Offline pack: ${status.packedPages}/${status.totalPages} '
          'chapters$incomplete';
    }
    if (status.isManga) {
      return 'Offline: ${status.imageFiles}/${status.totalPages} '
          'page images$incomplete';
    }
    return 'Offline: ${status.cachedPages}/${status.totalPages} pages$incomplete';
  }

  String _downloadingLabel(BookOfflineTask task) {
    switch (task.unit) {
      case BookOfflineUnit.bytes:
        final total = task.total > 0 ? ' / ${_formatBytes(task.total)}' : '';
        return 'Downloading PDF: ${_formatBytes(task.done)}$total';
      case BookOfflineUnit.chapters:
        return 'Downloading offline pack '
            '${task.done}/${task.total} chapters';
      case BookOfflineUnit.pages:
        return 'Downloading offline ${task.done}/${task.total} pages';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  Widget _buildStatusDistributionDetails(BuildContext context, List<int> dist) {
    final displayOrder = [98, 0, 1, 2, 3, 4, 5, 99];
    final total = dist.reduce((a, b) => a + b);

    return Column(
      children: displayOrder.map((statusNum) {
        final distIndex = [0, 1, 2, 3, 4, 5, 98, 99].indexOf(statusNum);
        final count = dist[distIndex];
        final isIgnored = statusNum == 98;
        final percentage = total > 0 ? ((count / total) * 100).round() : 0;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isIgnored
                      ? const Color(0x00000000)
                      : context.getStatusColorForVisualization(
                          statusNum.toString(),
                        ),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(
                    color: context.appColorScheme.text.secondary,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: isIgnored
                    ? Text(
                        'x',
                        style: TextStyle(
                          fontSize: 10,
                          color: context.appColorScheme.text.secondary,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _getStatusLabel(statusNum),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Text(
                '$count ($percentage%)',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<bool> _showConfirmDialog(
    BuildContext context,
    String title,
    String message,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: context.error),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  String _getStatusLabel(int status) {
    switch (status) {
      case 0:
        return 'Unknown (0)';
      case 1:
        return 'Learning (1)';
      case 2:
        return 'Learning (2)';
      case 3:
        return 'Learning (3)';
      case 4:
        return 'Learning (4)';
      case 5:
        return 'Learning (5)';
      case 98:
        return 'Ignored (98)';
      case 99:
        return 'Known (99)';
      default:
        return 'Unknown';
    }
  }
}
