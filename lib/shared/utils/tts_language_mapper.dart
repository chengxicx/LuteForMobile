/// 语言名 → BCP-47 语言标签，供服务端 TTS 使用。
///
/// 客户端把它拼进 `/tts/<lang>/<text>`，服务端 `voice_for_tag()` 据此选语音
/// （先精确匹配，再退到主语言子标签，最后才是默认语音）。
///
/// **这张表必须与服务端 `lute/tts/routes.py` 的 `LANG_NAME_TO_CODE` 保持一致。**
/// 对不上的后果不是「声音不好听」，而是彻底没有声音：把日文交给英文语音，
/// edge-tts 会返回 `NoAudioReceived`，服务端留下一个 0 字节的缓存文件，
/// 之后每次请求都返回 200 + 空响应体，客户端报
/// `Empty audio returned from Edge TTS server` —— 且永久失败。
///
/// 公开可见是为了让 `test/tts_language_mapper_test.dart` 能遍历它、
/// 逐个校验服务端是否真有对应语音。
const Map<String, String> ttsLanguageNameToTag = {
  'japanese': 'ja-JP',
  'english': 'en-US',
  'spanish': 'es-ES',
  'french': 'fr-FR',
  'german': 'de-DE',
  'chinese': 'zh-CN',
  'classical chinese': 'zh-CN',
  'simplified chinese': 'zh-CN',
  'traditional chinese': 'zh-TW',
  'mandarin': 'zh-CN',
  'mandarin chinese': 'zh-CN',
  'cantonese': 'zh-HK',
  'cantonese chinese': 'zh-HK',
  'italian': 'it-IT',
  'portuguese': 'pt-BR',
  'russian': 'ru-RU',
  'korean': 'ko-KR',
  'arabic': 'ar-EG',
  'hindi': 'hi-IN',
  'dutch': 'nl-NL',
  'polish': 'pl-PL',
  'turkish': 'tr-TR',
  'vietnamese': 'vi-VN',
  'thai': 'th-TH',
  'indonesian': 'id-ID',
  'czech': 'cs-CZ',
  'greek': 'el-GR',
  'hebrew': 'he-IL',
  'swedish': 'sv-SE',
  'ukrainian': 'uk-UA',
  'latin': 'la',
  'norwegian': 'nb-NO',
  'finnish': 'fi-FI',
  'danish': 'da-DK',
  'romanian': 'ro-RO',
  'hungarian': 'hu-HU',
  'catalan': 'ca-ES',
  'bulgarian': 'bg-BG',
  'croatian': 'hr-HR',
  'persian': 'fa',
  'malay': 'ms-MY',
  // 服务端的 LANG_NAME_TO_CODE 用的是 ISO 639-1 的 'tl'（翻译接口也依赖它），
  // 而 edge-tts 的菲律宾语语音叫 fil-PH-*。服务端在 TTS 语音表里把 'tl'
  // 指到了 fil-PH-BlessicaNeural，所以客户端照发 'tl' 即可。
  'tagalog': 'tl',
};

/// 语言名认不出来时的兜底标签，与服务端 `DEFAULT_LANG_TAG` 同族。
const String defaultTtsLanguageTag = 'en';

/// 把 Lute 的语言名（如 `Japanese`）转成 TTS 用的语言标签（如 `ja-JP`）。
///
/// 传入 null / 空串 / 未知语言时返回 [defaultTtsLanguageTag]。
String ttsLanguageCodeFor(String? languageName) {
  if (languageName == null) return defaultTtsLanguageTag;
  final key = languageName.toLowerCase().trim();
  if (key.isEmpty) return defaultTtsLanguageTag;
  return ttsLanguageNameToTag[key] ?? defaultTtsLanguageTag;
}

/// 各语言的「朗读测试」例句，按主语言子标签索引。
///
/// 设置页的 Test Speech 必须用目标语种的句子：edge-tts 对「语音与文本语种
/// 不匹配」的输入会返回 NoAudioReceived，服务端会留下 0 字节缓存文件。
const Map<String, String> _sampleSentences = {
  'ja': 'これは音声合成のテストです。',
  'zh': '这是语音合成的测试。',
  'ko': '이것은 음성 합성 테스트입니다.',
  'es': 'Hola, esta es una prueba de síntesis de voz.',
  'fr': 'Bonjour, ceci est un test de synthèse vocale.',
  'de': 'Hallo, dies ist ein Test der Sprachausgabe.',
  'it': 'Ciao, questo è un test di sintesi vocale.',
  'pt': 'Olá, este é um teste de síntese de voz.',
  'ru': 'Привет, это тест синтеза речи.',
};

const String _defaultSampleSentence =
    'Hello, this is a test of the text to speech.';

/// 取一句与 [languageTag] 语种匹配的测试例句。
String ttsSampleSentenceFor(String? languageTag) {
  if (languageTag == null) return _defaultSampleSentence;
  final primary = languageTag.toLowerCase().split(RegExp(r'[-_]')).first.trim();
  return _sampleSentences[primary] ?? _defaultSampleSentence;
}
