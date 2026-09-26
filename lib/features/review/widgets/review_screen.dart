import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/session_manager.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/widgets/error_display.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../reader/providers/sentence_tts_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/review_models.dart';
import '../providers/review_provider.dart';

/// Spaced-repetition review of due terms, mirroring the web review session
/// (`/review/session`): recognition cards show the term, cloze cards show
/// the sentence with the term blanked out; both are graded with the two
/// FSRS buttons (Again / Good) and pronounced with TTS.
class ReviewScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const ReviewScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final TextEditingController _typingController = TextEditingController();

  @override
  void dispose() {
    _typingController.dispose();
    super.dispose();
  }

  void _speak(ReviewCard card) {
    if (card.termText.isEmpty) return;
    ref.read(sentenceTTSProvider.notifier).speakSentence(card.termText, card.id);
  }

  void _startSession() {
    _typingController.clear();
    ref.read(reviewProvider.notifier).startSession();
  }

  void _checkTyped() {
    final text = _typingController.text;
    _typingController.clear();
    ref.read(reviewProvider.notifier).checkTyped(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reviewProvider);

    // 自动发音与 web 版一致：recognition 卡正面即发音；cloze 卡的词就是
    // 答案，在揭示或提交答案后才发音。顺带在换卡时清空打字框。
    ref.listen(reviewProvider, (prev, next) {
      if (prev == null || next.phase != ReviewPhase.active) return;
      final card = next.currentCard;
      if (card == null) return;
      final isNewCard =
          prev.currentCard?.id != card.id || prev.phase != ReviewPhase.active;
      if (isNewCard) {
        _typingController.clear();
        if (card.isRecognition && !next.revealed && !next.graded) _speak(card);
      }
      if (card.isCloze &&
          ((!prev.revealed && next.revealed) || (!prev.graded && next.graded))) {
        _speak(card);
      }
    });

    return Scaffold(
      appBar: AppBar(
        leading: AppBarLeading(scaffoldKey: widget.scaffoldKey),
        title: const Text('Review'),
        actions: [
          if (state.hasUndo)
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip:
                  'Undo last grade (${state.undo!.termText} '
                  '${state.undo!.ratingLabel})',
              onPressed: state.busy
                  ? null
                  : () => ref.read(reviewProvider.notifier).undo(),
            ),
        ],
      ),
      body: switch (state.phase) {
        ReviewPhase.idle => _IdleBody(onStart: _startSession),
        ReviewPhase.loading => const LoadingIndicator(
          message: 'Loading your cards ...',
        ),
        ReviewPhase.active => _ActiveBody(
          state: state,
          typingController: _typingController,
          onCheckTyped: _checkTyped,
          onSpeak: _speak,
        ),
        ReviewPhase.done => _DoneBody(state: state, onStart: _startSession),
        ReviewPhase.error => _ErrorBody(state: state, onStart: _startSession),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Landing / done / error bodies
// ---------------------------------------------------------------------------

class _IdleBody extends StatelessWidget {
  final VoidCallback onStart;

  const _IdleBody({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.style, size: 56, color: context.appColorScheme.text.secondary),
          const SizedBox(height: 16),
          const Text('Review due terms with spaced repetition.'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Review'),
          ),
        ],
      ),
    );
  }
}

class _DoneBody extends StatelessWidget {
  final ReviewState state;
  final VoidCallback onStart;

  const _DoneBody({required this.state, required this.onStart});

  /// Why the queue is empty, mirroring the web session's explanation:
  /// "new waiting" with nothing served means the daily limit is the reason.
  String? get _nothingDueWhy {
    final c = state.counts;
    if (c == null) return null;
    final bits = <String>[];
    if (c.newRemaining > 0 && c.newAllowedToday == 0) {
      bits.add(
        '${c.newRemaining} new cards are waiting, but today\'s limit of '
        '${c.maxNewPerDay} is used up',
      );
    }
    if (c.due > 0) bits.add('${c.due} cards are due');
    return bits.isEmpty ? null : bits.join('; ');
  }

  @override
  Widget build(BuildContext context) {
    final why = state.nothingDue ? _nothingDueWhy : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              state.nothingDue ? Icons.event_available : Icons.celebration_outlined,
              size: 56,
              color: context.appColorScheme.text.secondary,
            ),
            const SizedBox(height: 16),
            Text(
              state.nothingDue ? 'Nothing to review right now.' : 'Session done.',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (why != null) ...[
              const SizedBox(height: 8),
              Text(
                '$why.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.appColorScheme.text.secondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends ConsumerWidget {
  final ReviewState state;
  final VoidCallback onStart;

  const _ErrorBody({required this.state, required this.onStart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Expanded(
          child: ErrorDisplay(
            message: state.errorMessage ?? 'Unknown error',
            onRetry: onStart,
          ),
        ),
        if (state.needsFsrs)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: FilledButton.icon(
              onPressed: state.busy
                  ? null
                  : () => ref.read(reviewProvider.notifier).installScheduler(),
              icon: const Icon(Icons.download),
              label: const Text('Install FSRS package on server'),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Session body
// ---------------------------------------------------------------------------

class _ActiveBody extends ConsumerWidget {
  final ReviewState state;
  final TextEditingController typingController;
  final VoidCallback onCheckTyped;
  final ValueChanged<ReviewCard> onSpeak;

  const _ActiveBody({
    required this.state,
    required this.typingController,
    required this.onCheckTyped,
    required this.onSpeak,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(reviewProvider.notifier);
    final card = state.currentCard;
    if (card == null) {
      return const ErrorDisplay(message: 'No card on screen');
    }

    return SafeArea(
      child: Column(
        children: [
          _ProgressHeader(state: state),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CardHeader(card: card),
                      const SizedBox(height: 16),
                      if (!state.revealed && !state.graded)
                        _QuestionSection(
                          card: card,
                          state: state,
                          typingController: typingController,
                          onCheckTyped: onCheckTyped,
                          onReveal: notifier.reveal,
                          onSpeak: onSpeak,
                        ),
                      if (state.graded) ...[
                        _TypedBanner(state: state),
                        const SizedBox(height: 12),
                        _AnswerSection(card: card, onSpeak: onSpeak),
                        const SizedBox(height: 16),
                        _NextButton(state: state, onNext: notifier.next),
                      ] else if (state.revealed) ...[
                        _AnswerSection(card: card, onSpeak: onSpeak),
                        const SizedBox(height: 16),
                        _GradeButtons(state: state, card: card),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  final ReviewState state;

  const _ProgressHeader({required this.state});

  @override
  Widget build(BuildContext context) {
    final total = state.cards.length;
    final value = total == 0 ? 0.0 : state.index / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: value, minHeight: 3),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            children: [
              Text(
                '${state.index + 1} / $total',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              if (state.notice != null)
                Expanded(
                  child: Text(
                    state.notice!,
                    style: TextStyle(fontSize: 12, color: context.warning),
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CardHeader extends StatelessWidget {
  final ReviewCard card;

  const _CardHeader({required this.card});

  @override
  Widget build(BuildContext context) {
    final badge = card.isRecognition ? 'Recognition' : 'Cloze';
    final prompt = card.isRecognition ? 'Recall the meaning' : 'Fill in the blank';
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: context.appColorScheme.border.outline),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            badge,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          prompt,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.appColorScheme.text.secondary,
          ),
        ),
      ],
    );
  }
}

class _QuestionSection extends ConsumerWidget {
  final ReviewCard card;
  final ReviewState state;
  final TextEditingController typingController;
  final VoidCallback onCheckTyped;
  final VoidCallback onReveal;
  final ValueChanged<ReviewCard> onSpeak;

  const _QuestionSection({
    required this.card,
    required this.state,
    required this.typingController,
    required this.onCheckTyped,
    required this.onReveal,
    required this.onSpeak,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (card.isRecognition) ...[
          _TermFront(card: card, onSpeak: onSpeak),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: state.busy ? null : onReveal,
            child: const Text('Show answer'),
          ),
        ] else ...[
          _ClozeFront(card: card),
          const SizedBox(height: 12),
          TextField(
            controller: typingController,
            enabled: !state.graded,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(hintText: 'your answer'),
            onSubmitted: (_) => onCheckTyped(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: state.busy ? null : onCheckTyped,
                child: const Text('Check'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: state.busy ? null : onReveal,
                  child: const Text('Show answer'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TermFront extends StatelessWidget {
  final ReviewCard card;
  final ValueChanged<ReviewCard> onSpeak;

  const _TermFront({required this.card, required this.onSpeak});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: SelectableText(
            card.termText,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.volume_up),
          tooltip: 'Pronounce the term',
          onPressed: () => onSpeak(card),
        ),
      ],
    );
  }
}

class _ClozeFront extends StatelessWidget {
  final ReviewCard card;

  const _ClozeFront({required this.card});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium;
    return SelectableText.rich(
      TextSpan(
        children: sentenceSpans(
          card.sentenceBlank ?? card.sentence,
          style ?? const TextStyle(fontSize: 16),
        ),
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _TypedBanner extends StatelessWidget {
  final ReviewState state;

  const _TypedBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final ok = state.typedCorrect;
    return Text(
      ok ? 'Correct' : 'Not quite -- the answer is ${state.typedAnswer}',
      style: TextStyle(
        fontWeight: FontWeight.w700,
        color: ok ? context.success : context.error,
      ),
    );
  }
}

class _AnswerSection extends ConsumerWidget {
  final ReviewCard card;
  final ValueChanged<ReviewCard> onSpeak;

  const _AnswerSection({required this.card, required this.onSpeak});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.appColorScheme.text.secondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!card.isRecognition)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: SelectableText(
                  card.termText,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.volume_up),
                tooltip: 'Pronounce the term',
                onPressed: () => onSpeak(card),
              ),
            ],
          ),
        if (card.romanization.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              card.romanization,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: muted, fontStyle: FontStyle.italic),
            ),
          ),
        if (card.sentence.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText.rich(
              TextSpan(
                children: sentenceSpans(
                  card.sentence,
                  Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
                ),
              ),
            ),
          ),
        if (card.translation.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
              card.translation,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        if (card.image != null) _CardImage(card: card),
      ],
    );
  }
}

class _CardImage extends ConsumerWidget {
  final ReviewCard card;

  const _CardImage({required this.card});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.read(settingsProvider).serverUrl;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: Image.network(
            _resolveImageUrl(card.image!, serverUrl),
            headers: SessionManager.authHeaders(),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class _GradeButtons extends ConsumerWidget {
  final ReviewState state;
  final ReviewCard card;

  const _GradeButtons({required this.state, required this.card});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(reviewProvider.notifier);
    final intervals = card.intervals;
    final againIv = intervals?.again ?? '';
    final goodIv = intervals?.good ?? '';

    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: context.error),
            onPressed: state.busy ? null : () => notifier.grade(1),
            child: Text(againIv.isEmpty ? 'Again' : 'Again ($againIv)'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: state.busy ? null : () => notifier.grade(3),
            child: Text(goodIv.isEmpty ? 'Good' : 'Good ($goodIv)'),
          ),
        ),
      ],
    );
  }
}

class _NextButton extends ConsumerWidget {
  final ReviewState state;
  final VoidCallback onNext;

  const _NextButton({required this.state, required this.onNext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: state.busy ? null : onNext,
      child: Text(state.typedCorrect ? 'Next' : 'Next (marked Again)'),
    );
  }
}

// ---------------------------------------------------------------------------
// Sentence markup helpers
// ---------------------------------------------------------------------------

/// Render the server's sentence markup as spans: the bold-tagged term shows
/// in bold and the cloze blank shows as literal [...].
List<TextSpan> sentenceSpans(String html, TextStyle style) {
  final boldStyle = style.copyWith(fontWeight: FontWeight.w700);
  final spans = <TextSpan>[];
  final boldPattern = RegExp(r'<b>(.*?)</b>', dotAll: true);
  var cursor = 0;
  for (final match in boldPattern.allMatches(html)) {
    if (match.start > cursor) {
      spans.add(_plainSpan(html.substring(cursor, match.start), style));
    }
    spans.add(TextSpan(text: _plainText(match.group(1) ?? ''), style: boldStyle));
    cursor = match.end;
  }
  if (cursor < html.length) {
    spans.add(_plainSpan(html.substring(cursor), style));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: _plainText(html), style: style));
  return spans;
}

TextSpan _plainSpan(String html, TextStyle style) {
  return TextSpan(text: _plainText(html), style: style);
}

String _plainText(String html) {
  var text = html.replaceAll(
    RegExp(r'<span class="cloze-blank">\[...\]</span>'),
    '[...]',
  );
  text = text.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

/// Server-relative /userimages paths need the server prefix; absolute URLs
/// pass through (same rule the term tooltip uses).
String _resolveImageUrl(String imageUrl, String serverUrl) {
  final trimmed = imageUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) return trimmed;
  final normalizedServer = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;
  final normalizedPath = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return '$normalizedServer$normalizedPath';
}
