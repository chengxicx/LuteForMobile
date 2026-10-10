/// Curated Edge TTS voice lists, keyed by the primary language subtag.
///
/// The full edge-tts catalogue is several hundred voices; readers only ever
/// need a handful of good ones per language.  The picker (player-bar gear
/// button and the settings row) filters this table by the primary subtag of
/// the language tag the book resolves to, and the free-text field covers
/// anything the table lacks.  The server independently validates the voice
/// (same-language gate), so a stale or wrong entry falls back to the default
/// voice rather than erroring.
library;

typedef EdgeVoice = ({String name, String label});

const Map<String, List<EdgeVoice>> kEdgeTtsVoicesByPrimarySubtag = {
  'ja': [
    (name: 'ja-JP-NanamiNeural', label: 'Nanami (female)'),
    (name: 'ja-JP-KeitaNeural', label: 'Keita (male)'),
    (name: 'ja-JP-AoiNeural', label: 'Aoi (female)'),
    (name: 'ja-JP-NaomiNeural', label: 'Naomi (female)'),
  ],
  'en': [
    (name: 'en-US-AriaNeural', label: 'Aria (female)'),
    (name: 'en-US-GuyNeural', label: 'Guy (male)'),
    (name: 'en-US-AndrewNeural', label: 'Andrew (male)'),
    (name: 'en-US-JennyNeural', label: 'Jenny (female)'),
    (name: 'en-GB-SoniaNeural', label: 'Sonia (female, UK)'),
    (name: 'en-GB-RyanNeural', label: 'Ryan (male, UK)'),
  ],
  'zh': [
    (name: 'zh-CN-XiaoxiaoNeural', label: '晓晓 (female, 普通话)'),
    (name: 'zh-CN-YunxiNeural', label: '云希 (male, 普通话)'),
    (name: 'zh-CN-YunyangNeural', label: '云扬 (male, 新闻)'),
    (name: 'zh-HK-HiuMaanNeural', label: '曉曼 (female, 粤语)'),
    (name: 'zh-HK-WanLungNeural', label: '雲龍 (male, 粤语)'),
    (name: 'zh-TW-HsiaoChenNeural', label: '曉臻 (female, 台灣)'),
  ],
  'ko': [
    (name: 'ko-KR-SunHiNeural', label: 'SunHi (female)'),
    (name: 'ko-KR-InJoonNeural', label: 'InJoon (male)'),
  ],
  'es': [
    (name: 'es-ES-ElviraNeural', label: 'Elvira (female)'),
    (name: 'es-ES-AlvaroNeural', label: 'Álvaro (male)'),
    (name: 'es-MX-DaliaNeural', label: 'Dalia (female, MX)'),
  ],
  'fr': [
    (name: 'fr-FR-DeniseNeural', label: 'Denise (female)'),
    (name: 'fr-FR-HenriNeural', label: 'Henri (male)'),
  ],
  'de': [
    (name: 'de-DE-KatjaNeural', label: 'Katja (female)'),
    (name: 'de-DE-ConradNeural', label: 'Conrad (male)'),
  ],
  'it': [
    (name: 'it-IT-ElsaNeural', label: 'Elsa (female)'),
    (name: 'it-IT-DiegoNeural', label: 'Diego (male)'),
  ],
  'ru': [
    (name: 'ru-RU-SvetlanaNeural', label: 'Svetlana (female)'),
    (name: 'ru-RU-DmitryNeural', label: 'Dmitry (male)'),
  ],
  'pt': [
    (name: 'pt-BR-FranciscaNeural', label: 'Francisca (female)'),
    (name: 'pt-BR-AntonioNeural', label: 'Antonio (male)'),
  ],
};

/// Primary language subtag of a BCP-47 tag ("ja-JP" -> "ja"), mirroring the
/// server-side gate: a voice is offered when its primary subtag matches.
String edgeVoicePrimarySubtag(String tag) =>
    tag.trim().split('-').first.toLowerCase();

/// Voices offered for [languageTag] (e.g. "ja-JP"), or const [] when the
/// language has no curated entry.
List<EdgeVoice> edgeVoicesForLanguage(String? languageTag) {
  if (languageTag == null) return const [];
  final primary = edgeVoicePrimarySubtag(languageTag);
  return kEdgeTtsVoicesByPrimarySubtag[primary] ?? const [];
}

/// Human label for a voice name ("ja-JP-KeitaNeural" -> "Keita"), used when a
/// stored custom voice is not in the curated table.
String edgeVoiceShortLabel(String name) {
  final parts = name.split('-');
  return parts.length >= 3 ? parts.sublist(2).join('-') : name;
}
