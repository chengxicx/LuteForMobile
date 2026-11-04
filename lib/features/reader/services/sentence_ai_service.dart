import 'dart:convert';

import '../../../core/network/api_service.dart';
import '../../../core/network/sse_parser.dart';
import '../models/sentence_ai_result.dart';

/// Reads the sentence AI SSE stream from [ApiService] and turns each frame
/// into a typed [SentenceAiEvent].
///
/// Shares the generic [SseParser] with the grammar panel, but keeps a
/// sentence-specific result model and event mapping.
class SentenceAiService {
  final ApiService _api;

  SentenceAiService(this._api);

  Stream<SentenceAiEvent> analyze({
    required String sentence,
    required int langId,
  }) async* {
    final response = await _api.postAiSentenceAnalysis(
      sentence: sentence,
      langId: langId,
    );
    final body = response.data;
    if (body == null) {
      throw const SentenceAiStreamException('The server returned no stream.');
    }

    final parser = SseParser();
    final raw = StringBuffer();
    var sawSseFrame = false;

    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      raw.writeln(line);
      final sse = parser.addLine(line);
      if (sse == null) continue;
      sawSseFrame = true;
      final event = parseSentenceAiEvent(sse);
      if (event != null) yield event;
    }

    final tail = parser.flush();
    if (tail != null) {
      sawSseFrame = true;
      final event = parseSentenceAiEvent(tail);
      if (event != null) yield event;
    }

    // Before the server-side upgrade, /ai/sentence could answer with a
    // one-line translation (plain text or a single JSON body) instead of SSE.
    // No SSE frame at all means we should treat the whole body as that old
    // answer rather than showing an empty result.
    if (!sawSseFrame) {
      final text = raw.toString().trim();
      if (text.isEmpty) return;
      final result = parseSentenceAiResultPayload(text);
      if (result != null && !result.isEmpty) {
        yield SentenceAiResultEvent(result: result);
      } else {
        yield SentenceAiResultEvent(fallbackText: text);
      }
    }
  }
}

class SentenceAiStreamException implements Exception {
  final String message;
  const SentenceAiStreamException(this.message);

  @override
  String toString() => message;
}
