/// 把 Sentence Reader 合并出来的长句拆回一个个「服务端单句」候选。
///
/// 服务端 `airesults` 按它自己的切句存结果（如 `あ、やっとつながった。`），
/// 而 App 的「句子合并」会把相邻短句拼成一句再请求 AI
/// （`あ、やっとつながった。 今日はどうしたんですか。`）。整本离线下载
/// 从 `/ai/library/export` 拉回的是前一种，用合并句算缓存 key 会全 miss。
/// 精确 key 没命中时，用这里拆出的片段各自查一次缓存即可把已有的解释
/// 拼回来 —— 不用重新下载、不用改服务端、也不用复刻合并规则。
library;

/// 一条合并句最多查多少个片段。只是防止异常长文本导致无意义的批量查表：
/// 超限时**取前 N 段**而不是整句放弃 —— 真机上 Sentence Reader 把整页
/// 课文合成一句，按句读会拆出 20+ 段，早先 12 段的上限让所有长句都
/// 直接返回空、片段回退完全没跑（1.4.58 实测）。
const int maxSentenceFragments = 64;

/// 有序、去重的片段列表。返回空列表表示「拆不出更小的句子」，调用方
/// 应跳过片段回退（整句本身已经查过一次了）。
///
/// 先按句末标点切（标点保留在片段里，服务端句子带标点）；没有句末标点
/// 时退化成按空白切 —— 合并器就是用空格把相邻句子连起来的。
List<String> splitCombinedSentence(String sentence) {
  final normalized = sentence
      .replaceAll('\u200b', '')
      .replaceAll('\u3000', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return const <String>[];

  final byPunctuation = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < normalized.length; i++) {
    final ch = normalized[i];
    buffer.write(ch);
    final nextIsSeparator = i + 1 == normalized.length ||
        normalized[i + 1] == ' ';
    // 半角句点只在后跟空白/结尾时才算句子结束，避免切开 "1.5" 之类。
    if (_isClauseEnd(ch) || (ch == '.' && nextIsSeparator)) {
      final part = buffer.toString().trim();
      if (part.isNotEmpty) byPunctuation.add(part);
      buffer.clear();
    }
  }
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) byPunctuation.add(tail);

  final parts = byPunctuation.length >= 2
      ? byPunctuation
      : normalized
          .split(' ')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();

  if (parts.length < 2) return const <String>[];

  final unique = <String>[];
  for (final part in parts.take(maxSentenceFragments)) {
    // 「ええっ！？」会被切成 '張：ええっ！' 和 '？' 两段；后者是纯标点，
    // 拼进译文只会多一行噪音，跳过。
    if (_isPunctuationOnly(part)) continue;
    if (!unique.contains(part)) unique.add(part);
  }
  return unique.length >= 2 ? unique : const <String>[];
}

bool _isPunctuationOnly(String part) =>
    RegExp(r'^[。．、！？!?.,，\s]+$').hasMatch(part);

bool _isClauseEnd(String ch) =>
    ch == '。' ||
    ch == '．' ||
    ch == '！' ||
    ch == '？' ||
    ch == '!' ||
    ch == '?';

/// 把多个片段的解释合成一份 `SentenceAiResult` 的 JSON。
///
/// 译文按片段顺序换行拼接，词条/语法/例句累加上去，语境取第一个非空的。
/// 字段名严格跟随服务端契约，`fromJson` 能直接读回；未知字段忽略，
/// 这样老结果或未来新增字段都不会让合并失败。
Map<String, dynamic> mergeSentenceAiResults(
  Iterable<Map<String, dynamic>> results,
) {
  final translations = <String>[];
  final segments = <dynamic>[];
  final grammar = <dynamic>[];
  final examples = <dynamic>[];
  String? context;

  for (final result in results) {
    final translation = result['translation'];
    if (translation is String && translation.trim().isNotEmpty) {
      translations.add(translation.trim());
    }
    _appendList(segments, result['segments']);
    _appendList(grammar, result['grammar']);
    _appendList(examples, result['examples']);
    if (context == null) {
      final value = result['context'];
      if (value is String && value.trim().isNotEmpty) {
        context = value.trim();
      }
    }
  }

  final merged = <String, dynamic>{};
  if (translations.isNotEmpty) {
    merged['translation'] = translations.join('\n');
  }
  if (segments.isNotEmpty) merged['segments'] = segments;
  if (grammar.isNotEmpty) merged['grammar'] = grammar;
  if (context != null) merged['context'] = context;
  if (examples.isNotEmpty) merged['examples'] = examples;
  return merged;
}

void _appendList(List<dynamic> target, dynamic value) {
  if (value is List) target.addAll(value);
}
