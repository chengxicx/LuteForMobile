import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/sse_parser.dart';
import 'package:song_mobile/features/grammar/models/ai_grammar_result.dart';
import 'package:song_mobile/features/grammar/services/ai_grammar_service.dart';

void main() {
  group('SseParser', () {
    test('collects event and multi-line data until a blank line', () {
      final parser = SseParser();

      expect(parser.addLine('event: text'), isNull);
      expect(parser.addLine('data: {"text":"hi"}'), isNull);
      final event = parser.addLine('');

      expect(event, isNotNull);
      expect(event!.event, 'text');
      expect(event.data, '{"text":"hi"}');
    });

    test('ignores comments and unknown fields', () {
      final parser = SseParser();

      expect(parser.addLine(': heartbeat'), isNull);
      expect(parser.addLine('id: 42'), isNull);
      expect(parser.addLine('retry: 1000'), isNull);
      expect(parser.addLine('event: done'), isNull);
      final event = parser.flush();

      expect(event?.event, 'done');
      expect(event?.data, isEmpty);
    });

    test('strips one optional space after the colon', () {
      final parser = SseParser();
      parser.addLine('data:  keep');
      final event = parser.flush();

      expect(event?.data, ' keep');
    });
  });

  group('parseAiGrammarEvent', () {
    test('meta carries cache/provider/model', () {
      final event = parseAiGrammarEvent(
        const SseEvent(
          event: 'meta',
          data: '{"cached":true,"provider":"anthropic","model":"m"}',
        ),
      );

      expect(event, isA<AiGrammarMetaEvent>());
      final meta = event as AiGrammarMetaEvent;
      expect(meta.cached, isTrue);
      expect(meta.provider, 'anthropic');
      expect(meta.model, 'm');
    });

    test('result tolerates missing translation and sections', () {
      final event = parseAiGrammarEvent(
        const SseEvent(
          event: 'result',
          data: '{"result":{"skeleton":{"subject":"I"},"pitfalls":["a",{"text":"b"}]}}',
        ),
      );

      expect(event, isA<AiGrammarResultEvent>());
      final result = (event as AiGrammarResultEvent).result!;
      expect(result.translation, isNull);
      expect(result.skeleton.subject, 'I');
      expect(result.skeleton.verb, isNull);
      expect(result.clauses, isEmpty);
      expect(result.pitfalls, ['a', 'b']);
    });

    test('result with fallback text', () {
      final event = parseAiGrammarEvent(
        const SseEvent(
          event: 'result',
          data: '{"fallback":true,"text":"plain answer"}',
        ),
      );

      final result = event as AiGrammarResultEvent;
      expect(result.result, isNull);
      expect(result.fallbackText, 'plain answer');
    });

    test('error keeps kind and message', () {
      final event = parseAiGrammarEvent(
        const SseEvent(
          event: 'error',
          data: '{"kind":"rate","message":"slow down"}',
        ),
      );

      final error = event as AiGrammarErrorEvent;
      expect(error.kind, 'rate');
      expect(error.message, 'slow down');
    });

    test('non-JSON error payload becomes an upstream error', () {
      final event = parseAiGrammarEvent(
        const SseEvent(event: 'error', data: 'Something broke'),
      );

      final error = event as AiGrammarErrorEvent;
      expect(error.kind, 'upstream');
      expect(error.message, 'Something broke');
    });
  });

  group('AiGrammarService', () {
    test('decodes a chunked SSE response into typed events', () async {
      final stream = _sseBytes([
        ': heartbeat\n\n',
        'event: meta\n',
        'data: {"cached":false,"provider":"openai","model":"gpt-4o-mini"}\n\n',
        'event: text\n',
        'data: {"text":"Hel"}\n\n',
        'event: text\n',
        'data: {"text":"lo"}\n\n',
        'event: result\n',
        'data: {"result":{"translation":"你好",'
            '"skeleton":{"subject":"I","verb":"am","object":"here"},'
            '"clauses":[{"type":"main","text":"I am here","role":"statement"}],'
            '"grammar_points":[{"name":"be + adj","role":"copula","fragment":"am here"}],'
            '"tense_voice":{"tense":"present","voice":"active","aspect":"simple"},'
            '"pitfalls":["Do not drop am"]}}\n\n',
        'event: done\n',
        'data: {}\n\n',
      ]);

      final api = _apiWith(stream);
      final events = await AiGrammarService(api)
          .analyze(sentence: 'I am here', langId: 2)
          .toList();

      expect(events.map((e) => e.runtimeType), [
        AiGrammarMetaEvent,
        AiGrammarTextEvent,
        AiGrammarTextEvent,
        AiGrammarResultEvent,
        AiGrammarDoneEvent,
      ]);

      final meta = events[0] as AiGrammarMetaEvent;
      expect(meta.provider, 'openai');
      expect(meta.cached, isFalse);

      final text = events
          .whereType<AiGrammarTextEvent>()
          .map((e) => e.text)
          .join();
      expect(text, 'Hello');

      final result = (events[3] as AiGrammarResultEvent).result!;
      expect(result.translation, '你好');
      expect(result.skeleton.object, 'here');
      expect(result.clauses.single.type, 'main');
      expect(result.grammarPoints.single.name, 'be + adj');
      expect(result.tenseVoice?.aspect, 'simple');
      expect(result.pitfalls, ['Do not drop am']);
    });

    test('closes an event the server did not terminate with a blank line',
        () async {
      final stream = _sseBytes([
        'event: result\n',
        'data: {"result":{"translation":"ok"}}',
      ]);

      final events = await AiGrammarService(
        _apiWith(stream),
      ).analyze(sentence: 'x', langId: 1).toList();

      expect(events.single, isA<AiGrammarResultEvent>());
      expect(
        (events.single as AiGrammarResultEvent).result?.translation,
        'ok',
      );
    });
  });
}

ApiService _apiWith(Stream<Uint8List> stream) {
  final dio = Dio();
  dio.httpClientAdapter = _StreamAdapter(stream);
  return ApiService(baseUrl: 'http://test.local', dio: dio);
}

Stream<Uint8List> _sseBytes(List<String> parts) {
  // Deliberately re-chunk the UTF-8 bytes at arbitrary boundaries so the
  // decoder must handle a multi-byte character split across chunks.
  final bytes = Uint8List.fromList(utf8.encode(parts.join()));
  final chunks = <Uint8List>[];
  const chunkSize = 13;
  for (var i = 0; i < bytes.length; i += chunkSize) {
    chunks.add(
      bytes.sublist(
        i,
        i + chunkSize > bytes.length ? bytes.length : i + chunkSize,
      ),
    );
  }
  return Stream.fromIterable(chunks);
}

class _StreamAdapter implements HttpClientAdapter {
  final Stream<Uint8List> _body;

  _StreamAdapter(this._body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      _body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
