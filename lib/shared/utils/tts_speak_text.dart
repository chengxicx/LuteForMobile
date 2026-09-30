/// 单词发音的朗读文本：标注读音（romanization）非空时优先。
///
/// TTS 引擎按词的表层拼写发音，多音字/汉字词经常读错；用户在词卡上标注的
/// 读音（WoRomanization，日文场景通常存 kana）才是期望的发音。整句/整页
/// 朗读不做逐词替换 —— 那需要分词对齐，此处只服务"读一个词"的场景。
String ttsSpeakTextForTerm({required String term, String? reading}) {
  final trimmed = reading?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  return term;
}
