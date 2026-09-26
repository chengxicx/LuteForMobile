import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/providers/network_providers.dart';
import '../providers/books_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/book.dart';
import 'book_card.dart';
import 'book_details_dialog.dart';
import 'add_book_dialog.dart';
import 'book_filter_bar.dart';
import 'series_detail_screen.dart';
import 'package:song_mobile/app.dart';
import '../../../shared/theme/theme_extensions.dart';

class BooksScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const BooksScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends ConsumerState<BooksScreen> {
  final ScrollController _scrollController = ScrollController();
  int _buildCount = 0;

  /// 过滤面板（语言/tag chips）的展开状态：AppBar 过滤图标点击展开，
  /// 选中任一过滤后自动缩回。
  bool _filtersExpanded = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      final state = ref.read(booksProvider);
      if (state.showArchived) {
        ref.read(booksProvider.notifier).loadMoreArchivedBooks();
      } else {
        ref.read(booksProvider.notifier).loadMoreActiveBooks();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('BooksScreen', _buildCount);

    final state = ref.watch(booksProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
        title: const Text('Books'),
        actions: [
          // 搜索收进图标（对齐 web 顶栏的低存在感）：有激活搜索词时加小圆点提示。
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'Search books',
                icon: const Icon(Icons.search),
                onPressed: _showSearchDialog,
              ),
              if (state.searchQuery.isNotEmpty)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          // 语言/tag 过滤入口：点击展开面板，选中过滤后自动缩回。
          // 有生效的语言或 tag 过滤时加小圆点提示。
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'Filter by language / tag',
                icon: Icon(
                  _filtersExpanded ? Icons.filter_alt : Icons.filter_alt_outlined,
                ),
                onPressed: () =>
                    setState(() => _filtersExpanded = !_filtersExpanded),
              ),
              if (state.selectedTag != null ||
                  settings.languageFilter != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Add Book',
            icon: const Icon(Icons.add),
            onPressed: _showAddBookDialog,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(state.showArchived ? 'Show Archived' : 'Active Only'),
              selected: state.showArchived,
              onSelected: (_) {
                ref.read(booksProvider.notifier).toggleArchivedFilter();
              },
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final notifier = ref.read(booksProvider.notifier);
          await notifier.loadBooks(
            forceRefresh: true,
            skipExpiredBookRefresh: true,
          );
          if (ref.read(settingsProvider).autoRefreshFullStats) {
            await notifier.refreshExpiredBooks(forceRefreshAll: true);
          }
        },
        child: Column(
          children: [
            if (_filtersExpanded)
              BookFilterBar(
                onFilterSelected: () =>
                    setState(() => _filtersExpanded = false),
              ),
            Expanded(child: _buildBody(context, state, settings)),
          ],
        ),
      ),
    );
  }

  /// 搜索词通过弹窗输入（书架页顶栏保持干净）。
  /// 提交空串 = 清除搜索；取消不做任何改动。
  Future<void> _showSearchDialog() async {
    final controller = TextEditingController(
      text: ref.read(booksProvider).searchQuery,
    );
    final query = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Search books'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Title contains...',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          if (controller.text.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: const Text('Clear'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (query != null) {
      ref.read(booksProvider.notifier).setSearchQuery(query.trim());
    }
  }

  Widget _buildNoServerConfigured(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: context.appColorScheme.text.secondary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Server Connection',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Please configure your Song server in settings.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () =>
                  ref.read(navigationProvider).navigateToScreen('settings'),
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, BooksState state, settings) {
    if (state.isLoading) {
      return const LoadingIndicator(message: 'Loading books...');
    }

    final contentService = ref.watch(contentServiceProvider);
    if (!contentService.isConfigured) {
      return _buildNoServerConfigured(context);
    }

    if (state.errorMessage != null) {
      return ErrorDisplay(
        message: state.errorMessage!,
        onRetry: () {
          ref.read(booksProvider.notifier).loadBooks();
        },
      );
    }

    // tag 过滤激活时展示服务端返回的扁平书单（filtTag 精确匹配，
    // 聚合行已被服务端关闭）；否则按 Active/Archived 展示。
    if (state.selectedTag != null && state.tagFilterLoading) {
      return const LoadingIndicator(message: 'Filtering by tag...');
    }

    var books = state.selectedTag != null
        ? (state.tagFilteredBooks ?? const <Book>[])
        : (state.showArchived ? state.archivedBooks : state.activeBooks);

    if (settings.languageFilter != null) {
      books = books
          .where((b) => b.language == settings.languageFilter)
          .toList();
    }

    if (books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.collections_bookmark,
                size: 64,
                color: context.appColorScheme.text.secondary,
              ),
              const SizedBox(height: 16),
              Text(
                state.selectedTag != null
                    ? 'No books with tag "${state.selectedTag}".'
                    : 'No books found.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                state.selectedTag != null
                    ? 'Try another tag or clear the filter.'
                    : 'Add books in Song server first.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final hasMore = state.showArchived
        ? state.hasMoreArchived
        : state.hasMoreActive;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: books.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < books.length) {
          final book = books[index];
          return BookCard(
            book: book,
            onTap: () => _openBook(context, book),
            onLongPress: () => _showBookDetails(context, book),
          );
        } else {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
      },
    );
  }

  /// 卡片点击入口。
  ///
  /// Book Set 聚合行没有自己的 BkID，点开它只会去请求 /book/edit/0 然后
  /// 打开空白阅读器；所以聚合行改为进入系列列表页。
  void _openBook(BuildContext context, Book book) {
    if (book.isSeries) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(series: book),
        ),
      );
      return;
    }
    // 显式把 Book 传下去：系列列表页打开成员书时它并不在书架列表里，
    // 不传就会退化成一本没有标题和语言的空壳书。
    ref.read(navigationProvider).navigateToReader(book.id, null, book);
  }

  Future<void> _showAddBookDialog() async {
    final contentService = ref.read(contentServiceProvider);
    if (!contentService.isConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configure your Song server in Settings first.'),
        ),
      );
      return;
    }

    final newBookId = await showDialog<int>(
      context: context,
      builder: (_) => const AddBookDialog(),
    );

    if (newBookId != null && mounted) {
      ref.read(navigationProvider).navigateToReader(newBookId, null);
    }
  }

  void _showBookDetails(BuildContext context, Book book) {
    // 聚合行不能走 BookDetailsDialog：那里的归档/删除按钮会打到
    // /book/archive/0、/book/delete/0 上，而聚合行根本没有 BkID。
    if (book.isSeries) {
      _showSeriesDetails(context, book);
      return;
    }

    final state = ref.read(booksProvider);
    final isArchived = state.archivedBooks.any((b) => b.id == book.id);
    showDialog(
      context: context,
      builder: (context) =>
          BookDetailsDialog(book: book, isArchived: isArchived),
    );
  }

  void _showSeriesDetails(BuildContext context, Book book) {
    final read = book.seriesReadCount ?? 0;
    final total = book.seriesCount;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(book.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Book Set · $total books'),
            const SizedBox(height: 4),
            Text('$read of $total read'),
            const SizedBox(height: 4),
            Text('${book.wordCount} words in total'),
            const SizedBox(height: 12),
            Text(
              'Tap "Browse" to see the books in this set.',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _openBook(context, book);
            },
            child: const Text('Browse'),
          ),
        ],
      ),
    );
  }
}
