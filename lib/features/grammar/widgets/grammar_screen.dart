import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart';
import '../../../core/logger/widget_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../reader/providers/reader_provider.dart';
import '../models/grammar_point.dart';
import '../providers/grammar_provider.dart';

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
          ...state.points.map(
            (point) => GrammarPointCard(point: point),
          ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.bookTitle ?? 'Current page',
          style: Theme.of(context).textTheme.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          'Page ${state.pageNum ?? '-'} · $total grammar point'
          '${total == 1 ? '' : 's'} · $examples example'
          '${examples == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.appColorScheme.text.secondary,
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
            Icon(icon, size: 64, color: context.appColorScheme.text.secondary),
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

/// One grammar point: name, level badge, explanation, example sentences.
class GrammarPointCard extends StatelessWidget {
  final GrammarPoint point;

  const GrammarPointCard({super.key, required this.point});

  @override
  Widget build(BuildContext context) {
    final desc = point.desc;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    point.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (point.level != null) ...[
                  const SizedBox(width: 8),
                  _LevelBadge(level: point.level!),
                ],
              ],
            ),
            if (desc != null) ...[
              const SizedBox(height: 6),
              Text(
                desc,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                ),
              ),
            ],
            if (point.examples.isNotEmpty) const SizedBox(height: 12),
            ...point.examples.map(
              (example) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ExampleSentence(example: example),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final String level;

  const _LevelBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.m3SecondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        level,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: context.appColorScheme.text.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// An example sentence with the matched fragments marked.
class _ExampleSentence extends StatelessWidget {
  final GrammarExample example;

  const _ExampleSentence({required this.example});

  @override
  Widget build(BuildContext context) {
    final highlightStyle = TextStyle(
      backgroundColor: context.m3PrimaryContainer,
      color: context.appColorScheme.text.onPrimaryContainer,
      fontWeight: FontWeight.bold,
    );

    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      height: 1.4,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.appColorScheme.background.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          style: baseStyle,
          children: _spans(highlightStyle),
        ),
      ),
    );
  }

  List<TextSpan> _spans(TextStyle highlightStyle) {
    if (example.matches.isEmpty) {
      return [TextSpan(text: example.sentence)];
    }

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in example.matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: example.sentence.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: example.sentence.substring(match.start, match.end),
          style: highlightStyle,
        ),
      );
      cursor = match.end;
    }
    if (cursor < example.sentence.length) {
      spans.add(TextSpan(text: example.sentence.substring(cursor)));
    }
    return spans;
  }
}
