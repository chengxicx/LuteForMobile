import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/language_flag_mapper.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import 'package:song_mobile/app.dart';
import '../models/book.dart';
import '../providers/books_provider.dart';
import 'book_card.dart';
import 'book_details_dialog.dart';

/// Book Set（服务端 tag 聚合）的详情页。
///
/// 书架上的聚合行本身没有 BkID，不能当书打开；点它进入这里，列出该 tag
/// 下的成员书。成员书在书架列表里是被聚合行隐藏的，只能通过带 `filtTag`
/// 的请求单独取回（见 [BooksRepository.getSeriesBooks]）。
class SeriesDetailScreen extends ConsumerStatefulWidget {
  /// 书架上的聚合行，携带 tag 名、书数、语言等汇总信息。
  final Book series;

  const SeriesDetailScreen({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailScreen> createState() =>
      _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  List<Book>? _books;
  String? _error;
  bool _isLoading = true;

  /// 断网且本地没有这个书集的缓存时的状态。
  bool _offline = false;

  /// 聚合行的标题就是 tag 名（服务端 `agg.tagtext AS BkTitle`）。
  String get _tag =>
      (widget.series.seriesTag?.isNotEmpty ?? false)
      ? widget.series.seriesTag!
      : widget.series.title;

  @override
  void initState() {
    super.initState();
    // 网络回来时自己恢复。用户在隧道里看到 Offline，出了隧道不该还要手动点
    // 一次 Retry —— 而刚恢复的那几秒可达性标志可能还是旧值，此时点 Retry
    // 只会再看到一次 Offline，看起来像按钮坏了。
    ServerStatusManager.addListener(_onReachabilityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onReachabilityChanged() {
    if (!mounted) return;
    if (ServerStatusManager.isReachable && _offline) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    ServerStatusManager.removeListener(_onReachabilityChanged);
    super.dispose();
  }

  /// 服务端对同一个 tag 会按语言各出一行聚合行（GROUP BY seriestag, BkLgID），
  /// 所以成员列表也按本行语言收敛，保证卡片上的「N 本」和列表条数一致。
  ///
  /// 过滤只在显示层做，缓存里存的是全量：否则换个语言过滤就得再打一次网络。
  List<Book> _filterByLanguage(List<Book> all) {
    final lang = widget.series.language;
    if (lang.isEmpty) return all;
    return all.where((b) => b.language == lang).toList();
  }

  Future<void> _load() async {
    final hasBooksToShow = _books?.isNotEmpty ?? false;

    if (mounted) {
      setState(() {
        // 已经有列表时不要翻 _isLoading：否则一次刷新会把已有内容换成整屏
        // "Loading books..."。真的没东西可显示时才转。
        _isLoading = !hasBooksToShow;
        _error = null;
        _offline = false;
      });
    }

    // 先吃缓存。离线时这是唯一能让聚合行真正可点的东西 —— 书架缓存画得出
    // 聚合行，成员列表原先却只能打网络，于是断网点进去就永远停在 loading。
    if (!hasBooksToShow) {
      final cached = await ref
          .read(booksRepositoryProvider)
          .getSeriesBooksFromCache(_tag);
      if (cached != null && cached.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _books = _filterByLanguage(cached);
          _isLoading = false;
        });
      }
    }

    // 不可达时直接停手，不要去排队：ApiRequestQueue 会把请求扣在内存里，
    // 离线期间它的 completer 永不完成，await 就永远不返回 —— 这个屏原先
    // 就是被这一点挂住的（阅读器侥幸有 15s UI 超时兜着，这里没有）。
    if (!ServerStatusManager.isReachable) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _offline = _books == null || _books!.isEmpty;
      });
      return;
    }

    try {
      final all = await ref.read(booksRepositoryProvider).getSeriesBooks(_tag);
      await ref
          .read(booksRepositoryProvider)
          .saveSeriesBooksToCache(_tag, all);
      if (!mounted) return;
      setState(() {
        _books = _filterByLanguage(all);
        _isLoading = false;
      });
    } catch (e) {
      ApiLogger.logError('SeriesDetailScreen._load', e);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        // 已有缓存内容时不要把整屏换成错误页，保留能看的那份。
        if (_books == null || _books!.isEmpty) {
          _error = e.toString();
        }
      });
    }
  }

  /// 打开成员书。
  ///
  /// 成员书不在书架列表里，app.dart 的 `_handleNavigateToReader` 查不到它，
  /// 所以这里把 [Book] 一起传过去，避免兜底分支丢掉标题和语言。
  ///
  /// 顺序是「先导航、再 pop」：本页是压在主界面之上的独立路由，先 pop 的话
  /// 会先露出主界面原来的标签页（比如书架），下一帧才切到阅读器，闪一下。
  /// 先导航则阅读器已经就位，pop 时直接把阅读器推出来。
  void _openBook(Book book) {
    final navigator = Navigator.of(context);
    ref.read(navigationProvider).navigateToReader(book.id, null, book);
    navigator.pop();
  }

  /// 继续阅读目标：第一本没读完的书（与服务端 series.py 的挑选逻辑一致），
  /// 全部读完时退回第一本。
  Book? get _continueBook {
    final books = _books;
    if (books == null || books.isEmpty) return null;
    return books.firstWhere((b) => !b.isCompleted, orElse: () => books.first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tag, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _load,
          ),
        ],
      ),
      // RefreshIndicator 需要有可滚动子级，因此只在真正有列表时才包上；
      // 加载中/错误态交给各自的组件处理。
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const LoadingIndicator(message: 'Loading books...');
    }

    if (_error != null) {
      return ErrorDisplay(message: _error!, onRetry: _load);
    }

    if (_offline) {
      return ErrorDisplay(
        title: 'Offline',
        icon: Icons.cloud_off_outlined,
        message:
            'This book set has not been opened on this device yet, so there '
            'is nothing cached to show. Connect once and it will open '
            'without a connection afterwards.',
        onRetry: _load,
      );
    }

    final books = _books ?? const <Book>[];
    if (books.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            Icons.collections_bookmark_outlined,
            size: 64,
            color: context.appColorScheme.text.secondary,
          ),
          const SizedBox(height: 16),
          Text(
            'No books in this set.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'The tag "$_tag" no longer has any active books.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.appColorScheme.text.secondary,
            ),
          ),
        ],
      );
    }

    final continueBook = _continueBook;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        // 1 个汇总头部 + N 本书
        itemCount: books.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _SeriesSummaryHeader(
              series: widget.series,
              books: books,
              continueBook: continueBook,
              onContinue: continueBook == null
                  ? null
                  : () => _openBook(continueBook),
            );
          }
          final book = books[index - 1];
          return BookCard(
            book: book,
            onTap: () => _openBook(book),
            onLongPress: () => _showBookDetails(book),
          );
        },
      ),
    );
  }

  void _showBookDetails(Book book) {
    showDialog(
      context: context,
      builder: (context) =>
          BookDetailsDialog(book: book, isArchived: false),
    );
  }
}

/// 系列汇总头部：书数、已读数、总词数、进度条与「继续阅读」入口。
class _SeriesSummaryHeader extends StatelessWidget {
  final Book series;
  final List<Book> books;
  final Book? continueBook;
  final VoidCallback? onContinue;

  const _SeriesSummaryHeader({
    required this.series,
    required this.books,
    required this.continueBook,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColorScheme;
    final target = continueBook;

    final total = books.length;
    final readCount = books.where((b) => b.isCompleted).length;
    final percent = total == 0 ? 0 : ((readCount * 100) / total).round();
    final totalWords = books.fold<int>(0, (sum, b) => sum + b.wordCount);
    final knownTerms = books.fold<int>(
      0,
      (sum, b) => sum + (b.distinctTerms ?? 0),
    );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.collections_bookmark, color: context.m3Primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    series.title,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  getFlagForLanguage(series.language) ?? '🌐',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(width: 4),
                Text(
                  series.language,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Book Set',
              style: textTheme.bodySmall?.copyWith(
                color: colors.text.secondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _stat(context, '$total books'),
                _stat(context, '$readCount read ($percent%)'),
                _stat(context, '${_thousands(totalWords)} words'),
                if (knownTerms > 0) _stat(context, '${_thousands(knownTerms)} terms'),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : readCount / total,
                minHeight: 8,
                backgroundColor: colors.background.surfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onContinue,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  target == null
                      ? 'No books to continue'
                      : 'Continue: ${target.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label) {
    return Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: context.appColorScheme.text.secondary,
      ),
    );
  }

  static String _thousands(int value) {
    final s = value.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }
}
