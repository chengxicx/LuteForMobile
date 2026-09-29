/// One grammar point found on a reading page.
///
/// Mirrors the JSON the web reader's "Analyze grammar" panel gets from
/// `GET /read/grammar_analysis/<bookid>/<pagenum>`:
///
/// ```json
/// [{ "name": "...", "level": "N4", "desc": "...",
///    "formation": "...", "notes": "...",
///    "reference": { "japanese": "...", "text": "...",
///                   "matches": [{ "start": 3, "end": 6 }] },
///    "examples": [{ "sentence": "...",
///                   "matches": [{ "start": 3, "end": 6 }] }] }]
/// ```
///
/// `level` and `desc` are not always present: the generic regex rule library
/// returns only `name` + `examples`, while the per-language engines (Sudachi
/// for Japanese, spaCy for the CEFR languages, ...) also carry a level and a
/// short explanation.
///
/// `formation`, `notes` and `reference` are Japanese-engine extras: the
/// curated JLPT entry's formation line, its usage notes, and the entry's own
/// reference example with the translation the backend picked for the panel's
/// display language (`reference.text`, already localized server-side).
/// All three are absent for other languages and for hand-written rules.
class GrammarPoint {
  final String name;
  final String? level;
  final String? desc;
  final String? formation;
  final String? notes;
  final GrammarReference? reference;
  final List<GrammarExample> examples;

  const GrammarPoint({
    required this.name,
    this.level,
    this.desc,
    this.formation,
    this.notes,
    this.reference,
    this.examples = const [],
  });

  factory GrammarPoint.fromJson(Map<String, dynamic> json) {
    final rawReference = json['reference'];
    return GrammarPoint(
      name: (json['name'] as String?)?.trim() ?? '',
      level: _asString(json['level']),
      desc: _asString(json['desc']),
      formation: _asString(json['formation']),
      notes: _asString(json['notes']),
      reference: rawReference is Map
          ? GrammarReference.fromJson(Map<String, dynamic>.from(rawReference))
          : null,
      examples: (json['examples'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => GrammarExample.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.sentence.isNotEmpty)
          .toList(),
    );
  }

  static String? _asString(dynamic value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }
}

/// A grammar point's curated reference example (Japanese engine only): the
/// library entry's own sentence, the matched fragments inside it, and the
/// translation in the panel's display language.
class GrammarReference {
  final String sentence;
  final String? text;
  final List<GrammarMatch> matches;

  const GrammarReference({
    required this.sentence,
    this.text,
    this.matches = const [],
  });

  factory GrammarReference.fromJson(Map<String, dynamic> json) {
    // The backend keys the sentence "japanese" (it is a Japanese-only
    // feature); the mobile model normalizes it to `sentence` like everywhere
    // else in this feature.
    final sentence = (json['japanese'] as String?) ?? '';
    final length = sentence.length;
    final matches = <GrammarMatch>[];

    for (final raw in (json['matches'] as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final start = _asInt(raw['start']);
      final end = _asInt(raw['end']);
      if (start == null || end == null) continue;
      final safeStart = start.clamp(0, length);
      final safeEnd = end.clamp(safeStart, length);
      if (safeEnd > safeStart) {
        matches.add(GrammarMatch(start: safeStart, end: safeEnd));
      }
    }

    matches.sort((a, b) => a.start.compareTo(b.start));
    return GrammarReference(
      sentence: sentence,
      text: GrammarPoint._asString(json['text']),
      matches: matches,
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}

/// One example sentence for a grammar point, with the substrings that matched.
class GrammarExample {
  final String sentence;
  final List<GrammarMatch> matches;

  const GrammarExample({required this.sentence, this.matches = const []});

  factory GrammarExample.fromJson(Map<String, dynamic> json) {
    final sentence = (json['sentence'] as String?) ?? '';
    final length = sentence.length;
    final matches = <GrammarMatch>[];

    for (final raw in (json['matches'] as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final start = _asInt(raw['start']);
      final end = _asInt(raw['end']);
      if (start == null || end == null) continue;
      // The server indexes into the sentence it sent; clamp anyway so a
      // mismatch can never produce a RangeError while building the spans.
      final safeStart = start.clamp(0, length);
      final safeEnd = end.clamp(safeStart, length);
      if (safeEnd > safeStart) {
        matches.add(GrammarMatch(start: safeStart, end: safeEnd));
      }
    }

    matches.sort((a, b) => a.start.compareTo(b.start));
    return GrammarExample(sentence: sentence, matches: matches);
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}

/// A `[start, end)` range of an example sentence that matched.
class GrammarMatch {
  final int start;
  final int end;

  const GrammarMatch({required this.start, required this.end});
}
