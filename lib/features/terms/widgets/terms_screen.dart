import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/terms_provider.dart';
import '../models/term.dart';
import 'term_card.dart';
import 'term_filter_panel.dart';
import 'term_edit_dialog_wrapper.dart';
import 'term_stats_panel.dart';

class TermsScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const TermsScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends ConsumerState<TermsScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  int _buildCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(termsProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('TermsScreen', _buildCount);

    final state = ref.watch(termsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
        title: const Text('Terms'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: () => _showFilterPanel(context),
            tooltip: 'Filters',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          Expanded(child: _buildTermsList(state)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search terms...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    ref.read(termsProvider.notifier).setSearchQuery('');
                  },
                )
              : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
        ),
        onChanged: (value) {
          ref.read(termsProvider.notifier).setSearchQuery(value);
        },
      ),
    );
  }

  Widget _buildTermsList(TermsState state) {
    if (state.isLoading && state.terms.isEmpty) {
      return const Center(child: LoadingIndicator());
    }

    // 断网 + 本地一份快照都没有：给 Offline，不要把 DioException 原文或
    // 「No terms found」拍给用户 —— 后者会让用户以为服务器上真的没有词。
    // 有快照时直接显示快照（和书架一致），不挡内容。
    if (state.isOffline && state.terms.isEmpty) {
      return ErrorDisplay(
        title: 'Offline',
        icon: Icons.cloud_off_outlined,
        message:
            'No terms cached on this device yet, and the server is '
            'unreachable. The list will refresh on its own once you are '
            'back online.',
        onRetry: () => ref.read(termsProvider.notifier).refreshTerms(),
      );
    }

    if (state.errorMessage != null) {
      return ErrorDisplay(
        message: state.errorMessage!,
        onRetry: () => ref.read(termsProvider.notifier).refreshTerms(),
      );
    }

    final slivers = <Widget>[
      if (state.terms.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.spellcheck,
                  size: 64,
                  color: context.appColorScheme.text.secondary,
                ),
                const SizedBox(height: 16),
                Text(
                  'No terms found',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (state.selectedLangId == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Showing terms from all languages'),
                  ),
              ],
            ),
          ),
        )
      else ...[
        if (state.selectedLangId != null)
          SliverToBoxAdapter(
            child: TermStatsPanel(selectedLangId: state.selectedLangId!),
          ),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index < state.terms.length) {
                return TermCard(
                  term: state.terms[index],
                  onTap: () => _showTermEditDialog(state.terms[index]),
                );
              } else if (state.hasMore) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return null;
            }, childCount: state.terms.length + (state.hasMore ? 1 : 0)),
          ),
        ),
      ],
    ];

    return RefreshIndicator(
      onRefresh: () => ref.read(termsProvider.notifier).refreshTerms(),
      child: CustomScrollView(controller: _scrollController, slivers: slivers),
    );
  }

  void _showFilterPanel(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => const TermFilterPanel(),
    );
  }

  void _showTermEditDialog(Term term) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => TermEditDialogWrapper(
        term: term,
        onSave: (updatedTerm) {
          ref.read(termsProvider.notifier).updateTermInList(updatedTerm);
        },
        onDelete: () async {
          await ref.read(termsProvider.notifier).deleteTerm(term.id);
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }
}
