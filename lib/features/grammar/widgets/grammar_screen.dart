import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../shared/theme/eink_scope.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../reader/providers/reader_provider.dart';
import '../providers/grammar_provider.dart';
import 'grammar_point_card.dart';

/// Grammar analysis of the page being read, mirroring the web reader's
/// "Analyze grammar" panel.
///
/// The analysis itself happens on the server; this screen shows what came
/// back: each grammar point with its explanation and the sentences on the
/// page that matched, with the matched words marked.
class GrammarScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const GrammarScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<GrammarScreen> createState() => _GrammarScreenState();
}

class _GrammarScreenState extends ConsumerState<GrammarScreen> {
  int _buildCount = 0;

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('GrammarScreen', _buildCount);

    final state = ref.watch(grammarProvider);
    final isVisible = ref.watch(currentScreenRouteProvider) == 'grammar';

    // Analyze on open, and again after a page turn -- but only while this
    // tab is the one on screen.  The tab lives in an IndexedStack, so it is
    // built and kept alive whether or not it is visible; analysing from
    // there would fire a request on every page turn in the reader.
    if (isVisible) {
      final page = ref.watch(readerProvider.select((s) => s.pageData));
      if (page == null) {
        if (state.hasBook) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _analyze();
          });
        }
      } else {
        final key = '${page.bookId}/${page.currentPage}';
        if (state.analyzedKey != key) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _analyze();
          });
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
        title: const Text('Grammar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Analyze again',
            onPressed: state.isLoading ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(context, state),
    );
  }

  /// Analyse the current page.  Called from `build`, so it must *not* force:
  /// a rebuild is not a request to re-analyse, and forcing here made every
  /// rebuild fire another request.
  void _analyze() {
    unawaited(ref.read(grammarProvider.notifier).analyzeCurrentPage());
  }

  /// Re-analyse on demand (the refresh button, Retry, pull to refresh).
  void _refresh() {
    unawaited(ref.read(grammarProvider.notifier).analyzeCurrentPage(force: true));
  }

  Widget _buildBody(BuildContext context, GrammarState state) {
    if (!state.hasBook) {
      return _buildEmpty(
        context,
        icon: Icons.menu_book,
        title: 'No Book Loaded',
        message: 'Open a book in the reader, then come back here to see the '
            'grammar used on the page.',
        action: ElevatedButton.icon(
          onPressed: () =>
              ref.read(navigationProvider).navigateToScreen('books'),
          icon: const Icon(Icons.collections_bookmark),
          label: const Text('Browse Books'),
        ),
      );
    }

    // Nothing analyzed yet counts as loading: the analysis is kicked off right
    // after this frame, and showing "no grammar points found" for one frame
    // first would be a lie.
    if (state.isLoading || state.analyzedKey == null) {
      return const LoadingIndicator(message: 'Analyzing grammar...');
    }

    if (state.errorMessage != null) {
      return ErrorDisplay(message: state.errorMessage!, onRetry: _refresh);
    }

    if (!state.hasResults) {
      return _buildEmpty(
        context,
        icon: Icons.spellcheck,
        title: 'No grammar points found',
        message:
            'Nothing in the grammar library matched this page. This is common '
            'for short or media pages.',
        action: OutlinedButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Analyze again'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _buildHeader(context, state),
          const SizedBox(height: 8),
          for (var i = 0; i < state.points.length; i++)
            GrammarPointCard(point: state.points[i], index: i),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, GrammarState state) {
    final total = state.points.length;
    final examples = state.points.fold<int>(
      0,
      (sum, point) => sum + point.examples.length,
    );

    final eink = context.eInk;
    final colors = context.appColorScheme;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            // 墨水屏不铺色块：描边方框 + 墨色图标（实色，无 alpha）。
            color: eink ? null : context.m3PrimaryContainer,
            borderRadius: BorderRadius.circular(10),
            border: eink
                ? Border.all(color: colors.border.outline, width: 1.5)
                : null,
          ),
          child: Icon(
            Icons.spellcheck,
            size: 22,
            color: eink ? colors.text.primary : context.m3Primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.bookTitle ?? 'Current page',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Page ${state.pageNum ?? '-'} · $total grammar point'
                '${total == 1 ? '' : 's'} · $examples example'
                '${examples == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.eInk ? null : context.m3PrimaryContainer,
                border: context.eInk
                    ? Border.all(
                        color: context.appColorScheme.border.outline,
                        width: 1.5,
                      )
                    : null,
              ),
              child: Icon(
                icon,
                size: 36,
                color: context.eInk
                    ? context.appColorScheme.text.primary
                    : context.m3Primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.appColorScheme.text.secondary,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      ),
    );
  }
}
