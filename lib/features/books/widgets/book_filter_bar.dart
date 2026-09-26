import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/books_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/providers/language_data_provider.dart';
import '../../../shared/theme/theme_extensions.dart';

/// 书架顶部的过滤面板：语言 chips + tag chips（对齐 web 端书单的
/// 语言下拉与 tag pill 过滤）。
///
/// 面板由 AppBar 的过滤图标控制展开/收起（与搜索图标同行）；选中任一
/// 语言或 tag 后通过 [onFilterSelected] 通知外层收起面板。
///
/// - 语言：单选，列表只含未冻结（active）的语言；若已保存的语言过滤
///   对应的语言后来被冻结，这里会自动清掉该过滤（对齐 web 下拉行为）。
/// - tag：单选，点选中的 chip 取消过滤；tag 候选从当前书架书籍的
///   TagList 聚合，与服务端 `filtTag` 精确匹配语义一致。
/// - 搜索词激活时在此显示可移除的 chip（搜索框本体收在 AppBar 图标里）。
class BookFilterBar extends ConsumerStatefulWidget {
  final VoidCallback? onFilterSelected;

  const BookFilterBar({super.key, this.onFilterSelected});

  @override
  ConsumerState<BookFilterBar> createState() => _BookFilterBarState();
}

class _BookFilterBarState extends ConsumerState<BookFilterBar> {
  bool _clearingFrozenFilter = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final booksState = ref.watch(booksProvider);
    final languagesAsync = ref.watch(activeLanguageNamesProvider);

    final activeLanguageNames =
        languagesAsync.asData?.value ?? const <String>[];

    // 已保存的语言过滤若对应已冻结的语言，自动清除（web 的下拉会直接
    // 排除冻结语言，持久化的选择随之失效）。
    if (!_clearingFrozenFilter &&
        languagesAsync.hasValue &&
        settings.languageFilter != null &&
        !activeLanguageNames.contains(settings.languageFilter)) {
      _clearingFrozenFilter = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await ref
            .read(settingsProvider.notifier)
            .updateLanguageFilter(null);
        await ref.read(booksProvider.notifier).loadBooks();
        _clearingFrozenFilter = false;
      });
    }

    final tags = _collectTags(booksState);

    final showLanguageRow = activeLanguageNames.length > 1 ||
        (activeLanguageNames.length == 1 &&
            settings.languageFilter != null);
    final showTagRow = tags.isNotEmpty;
    final hasSearch = booksState.searchQuery.isNotEmpty;

    if (!showLanguageRow && !showTagRow && !hasSearch) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLanguageRow)
          _chipScroll([
            _filterChip(
              context,
              label: 'All Languages',
              selected: settings.languageFilter == null,
              onSelected: (_) => _setLanguageFilter(null),
            ),
            ...activeLanguageNames.map(
              (name) => _filterChip(
                context,
                label: name,
                selected: settings.languageFilter == name,
                onSelected: (selected) =>
                    _setLanguageFilter(selected ? name : null),
              ),
            ),
          ]),
        if (showTagRow)
          _chipScroll([
            _filterChip(
              context,
              label: 'All Tags',
              selected: booksState.selectedTag == null,
              onSelected: (_) => _setTagFilter(null),
            ),
            ...tags.map(
              (tag) => _filterChip(
                context,
                label: tag,
                selected: booksState.selectedTag == tag,
                onSelected: (selected) =>
                    _setTagFilter(selected ? tag : null),
              ),
            ),
          ]),
        if (hasSearch)
          _chipScroll([
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: InputChip(
                label: Text('"${booksState.searchQuery}"'),
                onDeleted: () =>
                    ref.read(booksProvider.notifier).setSearchQuery(''),
                deleteIconColor: context.appColorScheme.text.secondary,
              ),
            ),
          ]),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _chipScroll(List<Widget> children) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: children,
      ),
    );
  }

  Widget _filterChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        onSelected: onSelected,
      ),
    );
  }

  Future<void> _setLanguageFilter(String? language) async {
    await ref.read(settingsProvider.notifier).updateLanguageFilter(language);
    await ref.read(booksProvider.notifier).loadBooks();
    widget.onFilterSelected?.call();
  }

  Future<void> _setTagFilter(String? tag) async {
    await ref.read(booksProvider.notifier).setTagFilter(tag);
    widget.onFilterSelected?.call();
  }

  /// 从当前书架（active + archived）聚合 tag 候选，去重排序。
  ///
  /// 与 web 一致：可选的 tag 来自列表里可见书籍携带的 tag；
  /// 聚合行的 TagList 是它自己的 series tag，也计入。
  List<String> _collectTags(BooksState state) {
    final tags = <String>{};
    for (final book in [...state.activeBooks, ...state.archivedBooks]) {
      for (final tag in book.tags ?? const <String>[]) {
        if (tag.isNotEmpty) tags.add(tag);
      }
    }
    final list = tags.toList()..sort();
    return list;
  }
}
