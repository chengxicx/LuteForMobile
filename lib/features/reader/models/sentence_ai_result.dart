import 'dart:convert';

import '../../../core/network/sse_parser.dart';

/// Structured result of `POST /ai/translate`.
///
/// Field names follow the server contract exactly:
/// `translation`, `segments`, `grammar`, `context`, `examples`.
/// Every field is optional so an older server that still returns a one-line
/// translation (or a cached result written before the upgrade) renders
/// without errors.
class SentenceAiResult {
  final String? translation;
  final List<SentenceAiSegment> segments;
  final List<SentenceAiGrammar> grammar;
  final String? context;
  final List<SentenceAiExample> examples;

  const SentenceAiResult({
    this.translation,
    this.segments = const [],
    this.grammar = const [],
    this.context,
    this.examples = const [],
  });

  bool get isEmpty =>
      translation == null &&
      segments.isEmpty &&
      grammar.isEmpty &&
      context == null &&
      examples.isEmpty;

  factory SentenceAiResult.fromJson(Map<String, dynamic> json) {
    return SentenceAiResult(
      translation: _text(json['translation']),
      segments: _mapList(json['segments'], SentenceAiSegment.fromJson),
      grammar: _mapList(json['grammar'], SentenceAiGrammar.fromJson),
      context: _text(json['context']),
      examples: _mapList(json['examples'], SentenceAiExample.fromJson),
    );
  }

  /// Field names mirror the server contract; null and empty-list fields are
  /// omitted so [fromJson]'s defaults round-trip losslessly.
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (translation != null) json['translation'] = translation;
    if (segments.isNotEmpty) {
      json['segments'] = segments.map((e) => e.toJson()).toList();
    }
    if (grammar.isNotEmpty) {
      json['grammar'] = grammar.map((e) => e.toJson()).toList();
    }
    if (context != null) json['context'] = context;
    if (examples.isNotEmpty) {
      json['examples'] = examples.map((e) => e.toJson()).toList();
    }
    return json;
  }
}

class SentenceAiSegment {
  final String? part;
  final String? reading;
  final String? meaning;
  final String? role;

  const SentenceAiSegment({
    this.part,
    this.reading,
    this.meaning,
    this.role,
  });

  bool get isEmpty =>
      part == null && reading == null && meaning == null && role == null;

  factory SentenceAiSegment.fromJson(Map<String, dynamic> json) {
    return SentenceAiSegment(
      part: _text(json['part']),
      reading: _text(json['reading']),
      meaning: _text(json['meaning']),
      role: _text(json['role']),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (part != null) json['part'] = part;
    if (reading != null) json['reading'] = reading;
    if (meaning != null) json['meaning'] = meaning;
    if (role != null) json['role'] = role;
    return json;
  }
}

class SentenceAiGrammar {
  final String? point;
  final String? explanation;
  final String? fragment;

  const SentenceAiGrammar({
    this.point,
    this.explanation,
    this.fragment,
  });

  bool get isEmpty => point == null && explanation == null && fragment == null;

  factory SentenceAiGrammar.fromJson(Map<String, dynamic> json) {
    return SentenceAiGrammar(
      point: _text(json['point']),
      explanation: _text(json['explanation']),
      fragment: _text(json['fragment']),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (point != null) json['point'] = point;
    if (explanation != null) json['explanation'] = explanation;
    if (fragment != null) json['fragment'] = fragment;
    return json;
  }
}

class SentenceAiExample {
  final String? source;
  final String? translation;

  const SentenceAiExample({this.source, this.translation});

  bool get isEmpty => source == null && translation == null;

  factory SentenceAiExample.fromJson(Map<String, dynamic> json) {
    return SentenceAiExample(
      source: _text(json['source']),
      translation: _text(json['translation']),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (source != null) json['source'] = source;
    if (translation != null) json['translation'] = translation;
    return json;
  }
}

sealed class SentenceAiEvent {
  const SentenceAiEvent();
}

class SentenceAiMetaEvent extends SentenceAiEvent {
  final bool cached;
  final String? provider;
  final String? model;

  const SentenceAiMetaEvent({
    this.cached = false,
    this.provider,
    this.model,
  });
}

class SentenceAiTextEvent extends SentenceAiEvent {
  final String text;

  const SentenceAiTextEvent(this.text);
}

class SentenceAiResultEvent extends SentenceAiEvent {
  final SentenceAiResult? result;

  /// One-line legacy answer or the server's plain-text fallback.  It is the
  /// whole translation, not a section.
  final String? fallbackText;

  const SentenceAiResultEvent({this.result, this.fallbackText});
}

class SentenceAiDoneEvent extends SentenceAiEvent {
  const SentenceAiDoneEvent();
}

class SentenceAiErrorEvent extends SentenceAiEvent {
  final String kind;
  final String message;

  const SentenceAiErrorEvent({required this.kind, required this.message});
}

/// Parses one SSE frame.  Like the grammar parser, unknown frames return null
/// so future server additions cannot break an older app.
SentenceAiEvent? parseSentenceAiEvent(SseEvent sse) {
  final raw = sse.data.trim();
  if (raw.isEmpty) {
    return sse.event == 'done' ? const SentenceAiDoneEvent() : null;
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    if (sse.event == 'error') {
      return SentenceAiErrorEvent(kind: 'upstream', message: raw);
    }
    if (sse.event == 'text' || sse.event == 'message') {
      return SentenceAiTextEvent(raw);
    }
    return null;
  }

  if (decoded is String) {
    // A server may send a JSON string containing the answer.
    if (sse.event == 'error') {
      return SentenceAiErrorEvent(kind: 'upstream', message: decoded);
    }
    if (sse.event == 'result') {
      return SentenceAiResultEvent(
        result: parseSentenceAiResultPayload(decoded),
      );
    }
    return SentenceAiTextEvent(decoded);
  }
  if (decoded is! Map) return null;

  final json = Map<String, dynamic>.from(decoded);

  switch (sse.event) {
    case 'meta':
      return SentenceAiMetaEvent(
        cached: json['cached'] == true,
        provider: _text(json['provider']),
        model: _text(json['model']),
      );
    case 'text':
      final text = json['text'];
      if (text is! String || text.isEmpty) return null;
      return SentenceAiTextEvent(text);
    case 'result':
      final payload = json.containsKey('result') ? json['result'] : json;
      var result = parseSentenceAiResultPayload(payload);
      var fallback = json['fallback'] == true
          ? _text(json['text']) ??
              (payload is String ? _text(payload) : null)
          : null;

      // The server falls back to plain text when its own JSON parser rejects
      // the model's reply.  Some replies are still a JSON object -- fenced, or
      // missing the final brace after a long `examples` array -- so try to
      // recover the structured sections instead of showing raw JSON.
      if (fallback != null && stripJsonFence(fallback).startsWith('{')) {
        final recovered = parseSentenceAiResultPayload(fallback);
        if (recovered != null && !recovered.isEmpty) {
          result = recovered;
          fallback = null;
        }
      }

      if (result == null && fallback == null) {
        final text = _text(json['text']);
        if (text != null) {
          return SentenceAiResultEvent(fallbackText: text);
        }
        return null;
      }
      return SentenceAiResultEvent(result: result, fallbackText: fallback);
    case 'done':
      return const SentenceAiDoneEvent();
    case 'error':
      return SentenceAiErrorEvent(
        kind: _text(json['kind']) ?? 'upstream',
        message: _text(json['message']) ?? 'The AI request failed.',
      );
    default:
      return null;
  }
}

/// Parses an already-decoded payload, or a JSON string that may be wrapped in
/// a ```json fence.  A non-JSON string becomes a translation-only result so
/// the pre-upgrade one-line response still displays.
SentenceAiResult? parseSentenceAiResultPayload(dynamic payload) {
  if (payload == null) return null;
  if (payload is Map) {
    return SentenceAiResult.fromJson(Map<String, dynamic>.from(payload));
  }
  if (payload is String) {
    final text = stripJsonFence(payload);
    if (text.isEmpty) return null;
    final decoded = _decodeJsonObject(text);
    if (decoded != null) {
      return SentenceAiResult.fromJson(decoded);
    }
    // Not JSON: the old endpoint returned a plain translation line.
    return SentenceAiResult(translation: text);
  }
  return null;
}

/// Decodes a JSON object, closing braces/brackets the model left off.
///
/// Real replies have arrived with the final `}` missing after a long
/// `examples` array; the server then ships them as a text fallback.  A
/// stack-based repair recovers those sections instead of showing raw JSON.
Map<String, dynamic>? _decodeJsonObject(String text) {
  for (final candidate in [text, _closeOpenJson(text)]) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Try the repaired candidate.
    }
  }
  return null;
}

/// Appends the missing quote/brackets so a truncated JSON object parses.
/// Returns the input unchanged when the braces already balance.
String _closeOpenJson(String text) {
  final stack = <String>[];
  var inString = false;
  var escaped = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    switch (ch) {
      case '"':
        inString = true;
      case '{':
        stack.add('}');
      case '[':
        stack.add(']');
      case '}':
      case ']':
        if (stack.isNotEmpty && stack.last == ch) stack.removeLast();
    }
  }

  if (!inString && stack.isEmpty) return text;

  final fixed = StringBuffer(text);
  if (inString) fixed.write('"');
  for (var i = stack.length - 1; i >= 0; i--) {
    fixed.write(stack[i]);
  }
  return fixed.toString();
}

/// Handles models that wrap JSON in ```json ... ``` even though the server
/// asked for plain JSON.
String stripJsonFence(String value) {
  var text = value.trim();
  // Models sometimes open with ```json but forget the opening fence, ending
  // the reply with ``` only; strip either side independently.
  if (text.startsWith('```')) {
    final firstNewline = text.indexOf('\n');
    if (firstNewline == -1) return text;
    text = text.substring(firstNewline + 1).trimRight();
  }
  if (text.endsWith('```')) {
    text = text.substring(0, text.length - 3).trimRight();
  }
  return text.trim();
}

String? _text(dynamic value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) parse) {
  if (value is! List) return const [];
  final items = <T>[];
  for (final item in value) {
    if (item is! Map) continue;
    final parsed = parse(Map<String, dynamic>.from(item));
    if (parsed is SentenceAiSegment && parsed.isEmpty) continue;
    if (parsed is SentenceAiGrammar && parsed.isEmpty) continue;
    if (parsed is SentenceAiExample && parsed.isEmpty) continue;
    items.add(parsed);
  }
  return items;
}
