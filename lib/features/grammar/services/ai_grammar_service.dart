import 'dart:convert';

import '../../../core/network/api_service.dart';
import '../../../core/network/sse_parser.dart';
import '../models/ai_grammar_result.dart';

/// Reads the AI grammar SSE stream from [ApiService] and turns each frame
/// into a typed [AiGrammarEvent].
class AiGrammarService {
  final ApiService _api;

  AiGrammarService(this._api);

  Stream<AiGrammarEvent> analyze({
    required String sentence,
    required int langId,
  }) async* {
    final response = await _api.postAiGrammarAnalysis(
      sentence: sentence,
      langId: langId,
    );
    final body = response.data;
    if (body == null) {
      throw const AiGrammarStreamException('The server returned no stream.');
    }

    final parser = SseParser();
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      final sse = parser.addLine(line);
      if (sse != null) {
        final event = parseAiGrammarEvent(sse);
        if (event != null) yield event;
      }
    }

    // A server that closes right after its last `data:` line (no trailing
    // blank line) still has one complete event left in the parser.
    final tail = parser.flush();
    if (tail != null) {
      final event = parseAiGrammarEvent(tail);
      if (event != null) yield event;
    }
  }
}
