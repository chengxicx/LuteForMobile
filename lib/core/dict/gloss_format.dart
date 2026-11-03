/// 本地词典释义的结构化解析——web 端 `lute/dict/gloss_format.py` 的
/// Dart 子集。
///
/// 词卡与建卡预填都要回答同一个问题：「这条释义的第一个义项是什么？」
/// 释义原文是多行纯文本（词性、义项、例句、See also 指针混在一起），
/// 平铺显示就只能把整段塞进卡片。这里的规则与 web 的 `parse_gloss`
/// 逐条对齐（行序、判定顺序、`_looks_like_kanji_example` 等），所以
/// mobile 取到的「第一条」与 web 端 `first_sense()` 是同一行文本。
///
/// 只覆盖词典池里日/中/英词典用到的行结构；韩语、德语、俄语的专用分支
/// 没有移植——那些语言没有装本机词典时不会走到这里。
library;

/// 一个释义块。[type] 取值与 web 端一致：
/// `xref` / `headword` / `pos` / `section` / `sense` / `example` / `note` /
/// `phonetic`。
class GlossBlock {
  const GlossBlock(
    this.type,
    this.text, {
    this.reading,
    this.translation,
    this.number,
  });

  final String type;
  final String text;
  final String? reading;
  final String? translation;
  final int? number;

  GlossBlock withTranslation(String? value) => GlossBlock(
    type,
    text,
    reading: reading,
    translation: value,
    number: number,
  );
}

// Hiragana, katakana (incl. prolonged sound mark), half-width katakana.
final RegExp _kanaRe = RegExp(r'[\u3040-\u30ff\uff66-\uff9d]');
final RegExp _cjkRe = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]');
final RegExp _leadRe = RegExp(r'[（(「『]');

final RegExp _xrefRe = RegExp(r'^See also:\s*(.+?)【([^】]*)】\s*$');
final RegExp _xrefEnRe = RegExp(
  r'^(?:See also|See|Compare|参看|参见|另见|同见)\s*[：:]\s*(.+?)\s*[。.]?\s*$',
);
final RegExp _headwordRe = RegExp(r'^(.+?)【([^】]*)】$');

const List<String> _sectionWords = ['惯用语', '补充说明', '惯用词组'];
const Set<String> _posChars = {
  '名', '代', '动', '自', '動', '他', '形', '副', '接', '续', '続', '感', '連',
  '助', '詞', '词', '头', '尾', '叹', 'の', '·', '・', '一', '二', '三', '类',
};

const int _noteMinChars = 45;

final RegExp _phoneticGroupRe = RegExp(r'/[^/]+/|\[[^\]]+\]');
final RegExp _phoneticLabelRe = RegExp(
  r'^[,;.\s]*(?:(?:BrE|NAmE|AmE|Br|Am|US|UK)[,;.\s]*)*$',
);

const Set<String> _enPosWords = {
  'n', 'v', 'vt', 'vi', 'adj', 'adv', 'art', 'abbr', 'aux', 'conj', 'interj',
  'int', 'neg', 'num', 'prep', 'pron', 'prefix', 'suffix', 'modal', 'part',
  'det', 't', 'i', 'c', 'u', 'f', 'm', 'noun', 'verb', 'adjective', 'adverb',
  'article', 'preposition', 'conjunction', 'pronoun', 'interjection',
  'exclamation', 'numeral', 'auxiliary', 'determiner', 'particle',
  'abbreviation',
};
const Set<String> _enPosFillers = {'and', '或', '和', '及'};

final RegExp _enPosPrefixRe = RegExp(
  r'^((?:(?:n|v|vt|vi|adj|adv|art|abbr|aux|conj|interj|int|neg|num|'
  r'prep|pron|prefix|suffix|modal|part|det)\.\s*){1,3})(\S.*)$',
);

final RegExp _numberedRe = RegExp(
  r'^(?:\((\d{1,2})\)|(\d{1,2})[.、)）])(?!\d)\s*(\S.*)$',
);
final RegExp _enSentenceRe = RegExp(
  r'''^["'‘“（(]?[A-Z][^.!?]*[.?!…]+["'’”）]*$''',
);
final RegExp _exampleMarkerRe = RegExp(r'^(?:[•▪●·◦‣\-–—]|\d{1,2}[.、)）])\s*');

final RegExp _circledRe = RegExp('[\u2460-\u2487]');
final RegExp _cjkPosPrefixRe = RegExp(
  r'^([名代动形副接连助词感叹]{1,2})[\s　]+(\S.*)$',
);

const int _kanjiExampleMaxChars = 12;

/// 释义原文 → 结构化块，顺序与 web 端 `parse_gloss` 一致。
List<GlossBlock> parseGloss(String? gloss) {
  if (gloss == null || gloss.trim().isEmpty) return const [];

  final lines = <String>[];
  for (final raw in gloss.split('\n')) {
    // web 的 `_segment_text`：折叠空白、丢掉空行。
    final line = raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');
    if (line.isNotEmpty) lines.add(line);
  }

  final blocks = <GlossBlock>[];
  int senseNo = 0;
  int? pendingExample;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final next = i + 1 < lines.length ? lines[i + 1] : null;

    var match = _xrefRe.firstMatch(line);
    if (match != null) {
      blocks.add(
        GlossBlock('xref', match.group(1)!, reading: match.group(2)),
      );
      pendingExample = null;
      continue;
    }
    match = _xrefEnRe.firstMatch(line);
    if (match != null) {
      blocks.add(GlossBlock('xref', match.group(1)!.trim()));
      pendingExample = null;
      continue;
    }

    if (blocks.isEmpty) {
      match = _headwordRe.firstMatch(line);
      if (match != null && _kanaRe.hasMatch(match.group(2)!)) {
        blocks.add(GlossBlock('headword', line));
        pendingExample = null;
        continue;
      }
    }

    if (_isPhonetic(line)) {
      blocks.add(GlossBlock('phonetic', line));
      pendingExample = null;
      continue;
    }

    final core = _stripSectionSuffix(line);
    if (_isPos(core)) {
      if (!(blocks.isNotEmpty &&
          blocks.last.type == 'pos' &&
          blocks.last.text == core)) {
        blocks.add(GlossBlock('pos', core));
        senseNo = 0;
      }
      pendingExample = null;
      continue;
    }
    if (_isEnPos(line)) {
      final label = line.replaceAll(RegExp(r'[,; ]+$'), '');
      if (!(blocks.isNotEmpty &&
          blocks.last.type == 'pos' &&
          blocks.last.text == label)) {
        blocks.add(GlossBlock('pos', label));
        senseNo = 0;
      }
      pendingExample = null;
      continue;
    }

    if (_sectionWords.contains(line)) {
      blocks.add(GlossBlock('section', line));
      senseNo = 0;
      pendingExample = null;
      continue;
    }

    if (_isEnSentence(line) && next != null && _cjkRe.hasMatch(next)) {
      blocks.add(GlossBlock('example', _stripExampleMarker(line)));
      pendingExample = blocks.length - 1;
      continue;
    }

    // web 的 `if _KANA_RE.search(line):` 是一条 if/elif 链的头：命中假名
    // 但「第一个括号前没有假名」时整条 elif 链都不执行（汉德例句、待译
    // 例句、汉字例句、圈号拆分都不走），直接落到底部的义项规则。所以
    // 「（すべきところ）」这种括号内假名的中文释义仍然是义项。
    var skipChainedExampleRules = false;
    if (_kanaRe.hasMatch(line)) {
      final lead = line.split(_leadRe).first;
      if (_kanaRe.hasMatch(lead)) {
        blocks.add(GlossBlock('example', line));
        pendingExample = blocks.length - 1;
        continue;
      }
      skipChainedExampleRules = true;
    }

    if (!skipChainedExampleRules) {
      // web 的 汉德分支：中文释义之后一句以句末标点收尾的中文，是例句
      // 源句（下一行才是它的译文）。
      if (pendingExample == null &&
          blocks.isNotEmpty &&
          (blocks.last.type == 'sense' || blocks.last.type == 'pos') &&
          _cjkRe.hasMatch(line) &&
          (line.endsWith('。') || line.endsWith('！') || line.endsWith('？'))) {
        blocks.add(GlossBlock('example', line));
        pendingExample = blocks.length - 1;
        continue;
      }

      if (pendingExample != null) {
        blocks[pendingExample] = blocks[pendingExample].withTranslation(line);
        pendingExample = null;
        continue;
      }

      if (_looksLikeKanjiExample(line, next)) {
        blocks.add(GlossBlock('example', line));
        pendingExample = blocks.length - 1;
        continue;
      }
    }

    if (!skipChainedExampleRules &&
        _circledRe.hasMatch(line) &&
        line.length > 24) {
      final pieces = line.split(_circledRe);
      final head = pieces.first.replaceAll(RegExp(r'^[ ,;]+|[ ,;]+$'), '');
      if (head.isNotEmpty) blocks.add(GlossBlock('note', head));
      // split 会丢掉分隔符，这里按出现顺序补回编号。
      final markers = _circledRe.allMatches(line).map((m) => m.group(0)!).toList();
      for (var k = 1; k < pieces.length; k++) {
        final text = pieces[k].trim();
        if (text.isEmpty) continue;
        final n = _circledNumber(markers[k - 1]);
        if (n != null) senseNo = n;
        blocks.add(GlossBlock('sense', text, number: n ?? senseNo));
      }
      pendingExample = null;
      continue;
    }

    if (line.length > _noteMinChars &&
        !line.contains('（') &&
        !line.contains('(') &&
        _cjkRe.hasMatch(line)) {
      blocks.add(GlossBlock('note', line));
      pendingExample = null;
      continue;
    }

    match = _numberedRe.firstMatch(line);
    if (match != null) {
      senseNo = int.parse(match.group(1) ?? match.group(2)!);
      blocks.add(
        GlossBlock('sense', match.group(3)!, number: senseNo),
      );
      pendingExample = null;
      continue;
    }

    match = _enPosPrefixRe.firstMatch(line);
    if (match != null && !_hasCjkOrKana(match.group(1)!)) {
      final prefix = match.group(1)!.trim();
      if (!(blocks.isNotEmpty &&
          blocks.last.type == 'pos' &&
          blocks.last.text == prefix)) {
        blocks.add(GlossBlock('pos', prefix));
        senseNo = 0;
      }
      senseNo++;
      blocks.add(GlossBlock('sense', match.group(2)!.trim(), number: senseNo));
      pendingExample = null;
      continue;
    }

    match = _cjkPosPrefixRe.firstMatch(line);
    if (match != null) {
      blocks.add(GlossBlock('pos', match.group(1)!));
      senseNo++;
      blocks.add(GlossBlock('sense', match.group(2)!.trim(), number: senseNo));
      pendingExample = null;
      continue;
    }

    senseNo++;
    blocks.add(GlossBlock('sense', line, number: senseNo));
    pendingExample = null;
  }

  return blocks;
}

/// 条目里的全部义项（按词典原始顺序）。
List<String> glossSenses(String? gloss) {
  final result = <String>[];
  for (final block in parseGloss(gloss)) {
    if (block.type == 'sense' && block.text.trim().isNotEmpty) {
      result.add(block.text.trim());
    }
  }
  return result;
}

/// 与 web 端 `first_sense()` 相同：第一个义项，没有义项时为 null。
String? firstSense(String? gloss) {
  final senses = glossSenses(gloss);
  return senses.isEmpty ? null : senses.first;
}

/// 与 web 端 `xrefs()` 相同：按顺序排列的 See also 指针。
List<GlossBlock> glossXrefs(String? gloss) {
  return [
    for (final block in parseGloss(gloss))
      if (block.type == 'xref') block,
  ];
}

/// 建卡翻译的预填：已有翻译 > 用户在词卡里切过的义项 > 词典第一条。
///
/// 「已有翻译」不动，避免编辑一个已经翻好的词条时把它覆盖掉；用户
/// 在词卡里切换过义项就尊重那次选择；否则按 web 的 `first_sense`
/// 取第一条。
String? autoFillTranslation({
  String? existing,
  String? chosen,
  String? gloss,
}) {
  final current = (existing ?? '').trim();
  if (current.isNotEmpty) return existing;
  final picked = (chosen ?? '').trim();
  if (picked.isNotEmpty) return chosen;
  return firstSense(gloss);
}

// ------------------------------------------------------------------ helpers

bool _hasCjkOrKana(String text) =>
    _cjkRe.hasMatch(text) || _kanaRe.hasMatch(text);

bool _isPhonetic(String line) {
  if (line.length > 48 || _hasCjkOrKana(line)) return false;
  if (!_phoneticGroupRe.hasMatch(line)) return false;
  final remainder = line.replaceAll(_phoneticGroupRe, '');
  return _phoneticLabelRe.hasMatch(remainder);
}

bool _isEnPos(String line) {
  if (line.length > 24 || _hasCjkOrKana(line)) return false;
  final stripped = line
      .replaceFirst(RegExp(r'[（(][^）)]*[）)]\s*$'), '')
      .replaceAll(RegExp(r'[ .]+$'), '');
  final tokens = stripped
      .split(RegExp(r'[/,;·、&\s]+'))
      .where((t) => t.isNotEmpty)
      .map((t) => t.replaceAll(RegExp(r'\.'), '').replaceAll(RegExp(r'[\[\]]'), '').toLowerCase())
      .toList();
  if (tokens.isEmpty) return false;
  return tokens.any(_enPosWords.contains) &&
      tokens.every((t) => _enPosWords.contains(t) || _enPosFillers.contains(t));
}

String _stripExampleMarker(String line) =>
    line.replaceFirst(_exampleMarkerRe, '');

bool _isEnSentence(String line) {
  final stripped = _stripExampleMarker(line);
  return !_hasCjkOrKana(stripped) &&
      stripped.contains(' ') &&
      stripped.length >= 5 &&
      _enSentenceRe.hasMatch(stripped);
}

bool _isPos(String line) =>
    line.isNotEmpty &&
    line.length <= 12 &&
    line.split('').every(_posChars.contains);

String _stripSectionSuffix(String line) {
  for (final word in _sectionWords) {
    if (line.endsWith(word) && line != word) {
      return line.substring(0, line.length - word.length);
    }
  }
  return line;
}

bool _looksLikeKanjiExample(String line, String? following) {
  return _cjkRe.hasMatch(line) &&
      following != null &&
      line.length <= _kanjiExampleMaxChars &&
      !line.endsWith('。') &&
      !_kanaRe.hasMatch(following) &&
      following.endsWith('。') &&
      !following.startsWith('See also');
}

int? _circledNumber(String marker) {
  const bases = [0x2460, 0x2474];
  final code = marker.codeUnitAt(0);
  for (final base in bases) {
    if (code >= base && code < base + 20) return code - base + 1;
  }
  return null;
}
