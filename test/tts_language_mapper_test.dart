import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/shared/utils/tts_language_mapper.dart';

/// 服务端 `lute/tts/routes.py` 里 VOICE_MAP 的键。
///
/// 服务端 `voice_for_tag()` 先精确匹配整个标签，再退到主语言子标签，
/// 都命中不了就用 DEFAULT_VOICE（英文）。所以客户端产出的任何标签，
/// 至少要命中其中之一，否则就是「用英文语音念日文」——edge-tts 会返回
/// NoAudioReceived，朗读彻底没有声音。
const Set<String> _serverVoiceMapKeys = {
  'ja', 'en', 'es', 'fr', 'de', 'zh', 'hi', 'ru', 'ko', 'ar', 'it', 'pt',
  'tr', 'nl', 'pl', 'cs', 'th', 'id', 'vi', 'el', 'he', 'sv', 'uk', 'no',
  'nb', 'fi', 'da', 'ro', 'hu', 'ca', 'bg', 'hr', 'fa', 'ms', 'tl',
  'zh-CN', 'zh-TW', 'zh-HK', 'yue',
};

/// edge-tts 没有拉丁语语音，`latin` 只能退回默认（英文）语音。
/// 这是已知且可接受的例外 —— 拉丁文交给英文语音不会触发 NoAudioReceived。
const Set<String> _knownVoiceGaps = {'la'};

void main() {
  group('ttsLanguageCodeFor', () {
    test('produces the same BCP-47 tags the server maps to', () {
      expect(ttsLanguageCodeFor('Japanese'), 'ja-JP');
      expect(ttsLanguageCodeFor('English'), 'en-US');
      expect(ttsLanguageCodeFor('Traditional Chinese'), 'zh-TW');
      expect(ttsLanguageCodeFor('Cantonese'), 'zh-HK');
      expect(ttsLanguageCodeFor('Norwegian'), 'nb-NO');
      // 服务端用 ISO 639-1 的 'tl'（翻译接口也依赖它），并在 TTS 语音表里
      // 把 'tl' 指到 fil-PH-* 语音。客户端照发 'tl'。
      expect(ttsLanguageCodeFor('Tagalog'), 'tl');
    });

    test('ignores case and surrounding whitespace', () {
      expect(ttsLanguageCodeFor('japanese'), 'ja-JP');
      expect(ttsLanguageCodeFor('  Japanese  '), 'ja-JP');
      expect(ttsLanguageCodeFor('TRADITIONAL CHINESE'), 'zh-TW');
    });

    test('falls back to the default tag for null / empty / unknown', () {
      expect(ttsLanguageCodeFor(null), defaultTtsLanguageTag);
      expect(ttsLanguageCodeFor(''), defaultTtsLanguageTag);
      expect(ttsLanguageCodeFor('   '), defaultTtsLanguageTag);
      expect(ttsLanguageCodeFor('Klingon'), defaultTtsLanguageTag);
    });
  });

  group('服务端契约', () {
    test('每个映射出来的标签，服务端都真有对应语音', () {
      for (final entry in ttsLanguageNameToTag.entries) {
        final tag = entry.value;
        if (_knownVoiceGaps.contains(tag)) continue;

        final primary = tag.toLowerCase().split('-').first;
        final resolved =
            _serverVoiceMapKeys.contains(tag) ||
            _serverVoiceMapKeys.contains(primary);

        expect(
          resolved,
          isTrue,
          reason:
              '「${entry.key}」映射到 "$tag"，但服务端 VOICE_MAP 里既没有 "$tag" '
              '也没有 "$primary"，会被静默换成英文语音。日文这类语种会直接 '
              'NoAudioReceived，朗读永久失败。',
        );
      }
    });

    test('已知例外只有拉丁语，且确实没有 edge-tts 语音', () {
      final gaps = ttsLanguageNameToTag.values
          .where(
            (tag) =>
                !_serverVoiceMapKeys.contains(tag) &&
                !_serverVoiceMapKeys.contains(tag.toLowerCase().split('-').first),
          )
          .toSet();
      expect(gaps, _knownVoiceGaps);
    });
  });

  group('ttsSampleSentenceFor', () {
    test('取的是该语种的句子，而不是英文', () {
      expect(ttsSampleSentenceFor('ja-JP'), contains('テスト'));
      expect(ttsSampleSentenceFor('zh-CN'), isNot(contains('Hello')));
      expect(ttsSampleSentenceFor('ko-KR'), isNot(contains('Hello')));
      expect(ttsSampleSentenceFor('ru-RU'), isNot(contains('Hello')));
    });

    test('未知标签退回英文句子', () {
      expect(ttsSampleSentenceFor(null), contains('Hello'));
      expect(ttsSampleSentenceFor('xx-YY'), contains('Hello'));
    });

    test('任何标签都能拿到非空句子', () {
      for (final tag in ttsLanguageNameToTag.values) {
        expect(ttsSampleSentenceFor(tag).trim(), isNotEmpty, reason: tag);
      }
    });
  });
}
