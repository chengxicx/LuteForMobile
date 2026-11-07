import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/widgets/epub_chapter_view.dart';

void main() {
  test('marks every id and follows the first sentence', () {
    final script = buildEpubSentenceHighlightScript(
      ids: {12, 34},
      background: '#f0e6c8',
      foreground: '#201a12',
      follow: true,
    );

    expect(script, contains('var ids = [12,34]'));
    expect(script, contains('.textsentence[data-sentence-id="'));
    expect(script, contains('background-color: #f0e6c8 !important'));
    expect(script, contains('color: #201a12 !important'));
    expect(script, contains('scrollIntoView'));
  });

  test('paged mode marks without scrolling', () {
    final script = buildEpubSentenceHighlightScript(
      ids: {7},
      background: '#f0e6c8',
      foreground: '#201a12',
      follow: false,
    );

    expect(script, contains('lute-tts-playing'));
    expect(script, contains('if (first && false)'));
  });

  test('empty ids clear the previous highlight', () {
    final script = buildEpubSentenceHighlightScript(
      ids: const {},
      background: '#f0e6c8',
      foreground: '#201a12',
      follow: true,
    );

    expect(script, contains('var ids = []'));
    expect(script, contains('if (!ids.length)'));
  });
}
