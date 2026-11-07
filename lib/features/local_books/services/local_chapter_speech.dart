import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;

import '../../../shared/utils/tts_language_mapper.dart';
import '../../reader/providers/tts_player_provider.dart';
import '../../shadowing/models/shadowing_sentence.dart';

/// Sentences and shadowing units extracted from one local EPUB chapter.
///
/// Local books keep only sanitised HTML on disk (no token stream like the
/// server's chapter pages), so the player derives sentences from text.  It
/// is deliberately a plain text split, not a morphological tokenizer: the
/// minimum player needs one entry per sentence, and scoring can grow a real
/// tokenizer later without changing this interface.
class LocalChapterSpeech {
  const LocalChapterSpeech({
    required this.ttsSentences,
    required this.shadowingSentences,
    this.languageName,
  });

  final List<TTSPlayerSentence> ttsSentences;
  final List<ShadowingSentence> shadowingSentences;
  final String? languageName;

  bool get isEmpty => ttsSentences.isEmpty;
}

/// Extracts speech units from a sanitised chapter page.
///
/// Never throws: a malformed chapter just yields an empty result and the
/// reader opens without a player.
LocalChapterSpeech extractLocalChapterSpeech(String rawHtml) {
  final document = html_parser.parse(rawHtml);
  final lang = document.documentElement?.attributes['lang'] ??
      document.body?.attributes['lang'];
  final languageName = ttsLanguageNameForCode(lang);

  final buffer = StringBuffer();
  _collectText(document.body, buffer);
  final text = buffer
      .toString()
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .trim();
  if (text.isEmpty) {
    return LocalChapterSpeech(
      ttsSentences: const [],
      shadowingSentences: const [],
      languageName: languageName,
    );
  }

  final sentences = _splitSentences(text);
  final tts = <TTSPlayerSentence>[];
  final shadowing = <ShadowingSentence>[];
  for (var i = 0; i < sentences.length; i++) {
    final sentence = sentences[i];
    final id = i + 1;
    tts.add(TTSPlayerSentence(sentenceId: id, text: sentence));
    final tokens = _tokensOf(sentence);
    // Whole-punctuation sentences score nothing in shadowing; skip them
    // there but keep them in the TTS list so the voice still pauses.
    if (tokens.isNotEmpty) {
      shadowing.add(
        ShadowingSentence(
          sentenceId: id,
          tokens: tokens,
          languageId: null,
          displayText: sentence,
        ),
      );
    }
  }

  return LocalChapterSpeech(
    ttsSentences: tts,
    shadowingSentences: shadowing,
    languageName: languageName,
  );
}

const Set<String> _blockTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'body',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'td',
  'th',
  'tr',
  'ul',
};

const Set<String> _skipTags = {'script', 'style', 'noscript', 'template'};

void _collectText(html.Node? node, StringBuffer out) {
  if (node == null) return;
  if (node is html.Text) {
    out.write(node.text);
    return;
  }
  if (node is! html.Element) return;
  if (_skipTags.contains(node.localName)) return;

  final block = _blockTags.contains(node.localName);
  if (block) out.write('\n');
  for (final child in node.nodes) {
    _collectText(child, out);
  }
  if (block) out.write('\n');
}

/// Splits on sentence-final punctuation and hard line breaks.
///
/// `.` only ends a sentence when followed by whitespace/end, so `3.14`
/// survives.  Abbreviations (`Mr. Smith`) still split; that is an accepted
/// approximation for the local-only player and easy to refine later.
List<String> _splitSentences(String text) {
  final result = <String>[];
  final current = StringBuffer();

  void flush() {
    final sentence = current.toString().trim();
    current.clear();
    if (sentence.isNotEmpty) result.add(sentence);
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '\n') {
      flush();
      continue;
    }
    current.write(ch);
    final endsCjk = '。！？'.contains(ch);
    final endsAscii = ch == '?' || ch == '!';
    final endsDot = ch == '.' &&
        (i + 1 >= text.length || RegExp(r'\s').hasMatch(text[i + 1]));
    if (endsCjk || endsAscii || endsDot) flush();
  }
  flush();
  return result;
}

/// Word-ish units for shadowing: Latin words stay whole, CJK/kana/Hangul
/// characters become one unit each so a transcript can align at all.
final RegExp _tokenPattern = RegExp(
  '[A-Za-z0-9\u00C0-\u024F]+|[\\u3040-\\u30FF\\u3400-\\u9FFF\\uAC00-\\uD7AF]',
);

List<String> _tokensOf(String sentence) => _tokenPattern
    .allMatches(sentence)
    .map((m) => m.group(0)!)
    .toList(growable: false);
