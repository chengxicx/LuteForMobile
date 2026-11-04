import 'dart:convert';

import '../../../core/network/sse_parser.dart';

/// Structured grammar analysis returned by `POST /ai/grammar/analyze`.
///
/// Every field is optional: old cache entries and models that omit a section
/// still have to render, so parsing never assumes a shape.  `translation` is
/// the whole-sentence translation and is deliberately nullable -- the panel
/// shows nothing for it rather than an empty placeholder.
class AiGrammarResult {
  final String? translation;
  final AiGrammarSkeleton skeleton;
  final List<AiGrammarClause> clauses;
  final List<AiGrammarPoint> grammarPoints;
  final AiGrammarTenseVoice? tenseVoice;
  final List<String> pitfalls;

  const AiGrammarResult({
    this.translation,
    this.skeleton = const AiGrammarSkeleton(),
    this.clauses = const [],
    this.grammarPoints = const [],
    this.tenseVoice,
    this.pitfalls = const [],
  });

  bool get isEmpty =>
      translation == null &&
      skeleton.isEmpty &&
      clauses.isEmpty &&
      grammarPoints.isEmpty &&
      (tenseVoice?.isEmpty ?? true) &&
      pitfalls.isEmpty;

  factory AiGrammarResult.fromJson(Map<String, dynamic> json) {
    final rawSkeleton = json['skeleton'];
    final rawTenseVoice = json['tense_voice'];

    return AiGrammarResult(
      translation: _text(json['translation']),
      skeleton: rawSkeleton is Map
          ? AiGrammarSkeleton.fromJson(Map<String, dynamic>.from(rawSkeleton))
          : const AiGrammarSkeleton(),
      clauses: _mapList(json['clauses'], AiGrammarClause.fromJson),
      grammarPoints: _mapList(json['grammar_points'], AiGrammarPoint.fromJson),
      tenseVoice: rawTenseVoice is Map
          ? AiGrammarTenseVoice.fromJson(
              Map<String, dynamic>.from(rawTenseVoice),
            )
          : null,
      pitfalls: _pitfalls(json['pitfalls']),
    );
  }
}

class AiGrammarSkeleton {
  final String? subject;
  final String? verb;
  final String? object;

  const AiGrammarSkeleton({this.subject, this.verb, this.object});

  bool get isEmpty => subject == null && verb == null && object == null;

  factory AiGrammarSkeleton.fromJson(Map<String, dynamic> json) {
    return AiGrammarSkeleton(
      subject: _text(json['subject']),
      verb: _text(json['verb']),
      object: _text(json['object']),
    );
  }
}

class AiGrammarClause {
  final String? type;
  final String? text;
  final String? role;

  const AiGrammarClause({this.type, this.text, this.role});

  factory AiGrammarClause.fromJson(Map<String, dynamic> json) {
    return AiGrammarClause(
      type: _text(json['type']),
      text: _text(json['text']),
      role: _text(json['role']),
    );
  }
}

class AiGrammarPoint {
  final String? name;
  final String? role;
  final String? fragment;

  const AiGrammarPoint({this.name, this.role, this.fragment});

  bool get isEmpty => name == null && role == null && fragment == null;

  factory AiGrammarPoint.fromJson(Map<String, dynamic> json) {
    return AiGrammarPoint(
      name: _text(json['name']),
      role: _text(json['role']),
      fragment: _text(json['fragment']),
    );
  }
}

class AiGrammarTenseVoice {
  final String? tense;
  final String? voice;
  final String? aspect;

  const AiGrammarTenseVoice({this.tense, this.voice, this.aspect});

  bool get isEmpty => tense == null && voice == null && aspect == null;

  factory AiGrammarTenseVoice.fromJson(Map<String, dynamic> json) {
    return AiGrammarTenseVoice(
      tense: _text(json['tense']),
      voice: _text(json['voice']),
      aspect: _text(json['aspect']),
    );
  }
}

/// The events the AI grammar endpoint streams.
sealed class AiGrammarEvent {
  const AiGrammarEvent();
}

class AiGrammarMetaEvent extends AiGrammarEvent {
  final bool cached;
  final String? provider;
  final String? model;

  const AiGrammarMetaEvent({
    this.cached = false,
    this.provider,
    this.model,
  });
}

class AiGrammarTextEvent extends AiGrammarEvent {
  final String text;

  const AiGrammarTextEvent(this.text);
}

class AiGrammarResultEvent extends AiGrammarEvent {
  final AiGrammarResult? result;

  /// Set when the server could not produce structured JSON and fell back to
  /// showing the model's plain text.
  final String? fallbackText;

  const AiGrammarResultEvent({this.result, this.fallbackText});
}

class AiGrammarDoneEvent extends AiGrammarEvent {
  const AiGrammarDoneEvent();
}

class AiGrammarErrorEvent extends AiGrammarEvent {
  final String kind;
  final String message;

  const AiGrammarErrorEvent({required this.kind, required this.message});
}

/// Turns one parsed SSE frame into a typed event.
///
/// Unknown event names and non-JSON payloads return null: a future server
/// version adding a frame must not break the panel.
AiGrammarEvent? parseAiGrammarEvent(SseEvent sse) {
  final raw = sse.data.trim();
  if (raw.isEmpty) {
    return sse.event == 'done' ? const AiGrammarDoneEvent() : null;
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    if (sse.event == 'error') {
      return AiGrammarErrorEvent(kind: 'upstream', message: raw);
    }
    return null;
  }

  if (decoded is! Map) return null;
  final json = Map<String, dynamic>.from(decoded);

  switch (sse.event) {
    case 'meta':
      return AiGrammarMetaEvent(
        cached: json['cached'] == true,
        provider: _text(json['provider']),
        model: _text(json['model']),
      );
    case 'text':
      final text = json['text'];
      if (text is! String || text.isEmpty) return null;
      return AiGrammarTextEvent(text);
    case 'result':
      final rawResult = json['result'];
      AiGrammarResult? result;
      if (rawResult is Map) {
        result = AiGrammarResult.fromJson(
          Map<String, dynamic>.from(rawResult),
        );
      } else if (rawResult is String) {
        result = _tryParseResult(rawResult);
      }
      final fallbackText = json['fallback'] == true
          ? _text(json['text']) ?? (rawResult is String ? _text(rawResult) : null)
          // A server that sends plain text without the flag is still usable.
          : result == null
          ? _text(json['text'])
          : null;
      return AiGrammarResultEvent(result: result, fallbackText: fallbackText);
    case 'done':
      return const AiGrammarDoneEvent();
    case 'error':
      return AiGrammarErrorEvent(
        kind: _text(json['kind']) ?? 'upstream',
        message: _text(json['message']) ?? 'The AI request failed.',
      );
    default:
      return null;
  }
}

AiGrammarResult? _tryParseResult(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map
        ? AiGrammarResult.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  } catch (_) {
    return null;
  }
}

String? _text(dynamic value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) parse) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => parse(Map<String, dynamic>.from(item)))
      .where((item) {
        if (item is AiGrammarClause) {
          return item.text != null || item.type != null || item.role != null;
        }
        if (item is AiGrammarPoint) return !item.isEmpty;
        return true;
      })
      .toList();
}

List<String> _pitfalls(dynamic value) {
  if (value is! List) return const [];
  final items = <String>[];
  for (final item in value) {
    if (item is Map) {
      final text = _text(item['text']) ??
          _text(item['name']) ??
          _text(item['fragment']) ??
          _text(item['description']);
      if (text != null) items.add(text);
    } else {
      final text = _text(item);
      if (text != null) items.add(text);
    }
  }
  return items;
}

/// Stream-level failures that are not an `event: error` frame: a missing body,
/// or an HTTP/auth failure surfaced by Dio.
class AiGrammarStreamException implements Exception {
  final String message;
  const AiGrammarStreamException(this.message);

  @override
  String toString() => message;
}
