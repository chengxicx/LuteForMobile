import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/local_books/services/local_chapter_speech.dart';

void main() {
  test('splits block text into sentences and keeps ids aligned', () {
    final speech = extractLocalChapterSpeech('''
<html lang="ja-JP"><body>
<p>これは最初の文です。次の文です！</p>
<p>Hello world. This is the end.</p>
</body></html>
''');

    expect(speech.languageName, 'japanese');
    expect(speech.ttsSentences.map((s) => s.sentenceId), [1, 2, 3, 4]);
    expect(speech.ttsSentences[0].text, 'これは最初の文です。');
    expect(speech.ttsSentences[1].text, '次の文です！');
    expect(speech.ttsSentences[2].text, 'Hello world.');
    expect(speech.shadowingSentences.map((s) => s.sentenceId), [1, 2, 3, 4]);
    expect(
      speech.shadowingSentences.first.tokens,
      ['こ', 'れ', 'は', '最', '初', 'の', '文', 'で', 'す'],
    );
    expect(
      speech.shadowingSentences.first.displayText,
      'これは最初の文です。',
    );
  });

  test('skips scripts and styles, and reads the body lang fallback', () {
    final speech = extractLocalChapterSpeech('''
<html><body lang="en">
<script>var hidden = 1;</script>
<style>.x { color: red; }</style>
<p>Pi is 3.14 exactly.</p>
</body></html>
''');

    expect(speech.languageName, 'english');
    expect(speech.ttsSentences.map((s) => s.text), ['Pi is 3.14 exactly.']);
  });

  test('a chapter with no readable text yields an empty result', () {
    final speech = extractLocalChapterSpeech(
      '<html><body><script>var x = 1;</script></body></html>',
    );
    expect(speech.isEmpty, isTrue);
    expect(speech.shadowingSentences, isEmpty);
  });
}
