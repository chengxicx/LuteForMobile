import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/sse_parser.dart';
import 'package:song_mobile/features/reader/models/sentence_ai_result.dart';
import 'package:song_mobile/features/reader/services/sentence_ai_service.dart';

void main() {
  group('SentenceAiResult', () {
    test('parses every structured section', () {
      final result = parseSentenceAiResultPayload({
        'translation': '我在这里。',
        'segments': [
          {
            'part': 'I',
            'reading': '',
            'meaning': '我',
            'role': '主语',
          },
          {
            'part': 'am here',
            'reading': '',
            'meaning': '在这里',
            'role': '谓语',
          },
        ],
        'grammar': [
          {
            'point': 'be + 地点',
            'explanation': '表示当前位置',
            'fragment': 'am here',
          },
        ],
        'context': '这是对位置的回答。',
        'examples': [
          {
            'source': 'She is here.',
            'translation': '她在这里。',
          },
        ],
      })!;

      expect(result.translation, '我在这里。');
      expect(result.segments, hasLength(2));
      expect(result.segments.first.part, 'I');
      expect(result.segments.first.reading, isNull);
      expect(result.segments.last.meaning, '在这里');
      expect(result.grammar.single.point, 'be + 地点');
      expect(result.context, '这是对位置的回答。');
      expect(result.examples.single.source, 'She is here.');
    });

    test('tolerates missing fields and empty arrays', () {
      final result = parseSentenceAiResultPayload({
        'translation': '只回译文',
      })!;

      expect(result.translation, '只回译文');
      expect(result.segments, isEmpty);
      expect(result.grammar, isEmpty);
      expect(result.context, isNull);
      expect(result.examples, isEmpty);
      expect(result.isEmpty, isFalse);
    });

    test('ignores empty segment maps instead of rendering empty rows', () {
      final result = parseSentenceAiResultPayload({
        'segments': [
          {'part': '', 'reading': '', 'meaning': '', 'role': ''},
          {'part': 'word'},
        ],
      })!;

      expect(result.segments, hasLength(1));
      expect(result.segments.single.part, 'word');
    });

    test('parses JSON wrapped in a ```json fence', () {
      final result = parseSentenceAiResultPayload(
        '```json\n{"translation":"带围栏的译文","context":"说明"}\n```',
      )!;

      expect(result.translation, '带围栏的译文');
      expect(result.context, '说明');
    });

    test('plain text becomes a translation-only legacy result', () {
      final result = parseSentenceAiResultPayload('一行旧译文')!;

      expect(result.translation, '一行旧译文');
      expect(result.isEmpty, isFalse);
    });
  });

  group('parseSentenceAiEvent', () {
    test('result event accepts the contract shape', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'result',
          data: '{"result":{"translation":"你好","segments":[{"part":"Hello","meaning":"你好"}]}}',
        ),
      );

      final result = (event as SentenceAiResultEvent).result!;
      expect(result.translation, '你好');
      expect(result.segments.single.part, 'Hello');
    });

    test('result event accepts a bare result object without wrapper', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'result',
          data: '{"translation":"旧版","context":"ctx"}',
        ),
      );

      final result = (event as SentenceAiResultEvent).result!;
      expect(result.translation, '旧版');
      expect(result.context, 'ctx');
    });

    test('result event accepts a JSON string payload', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'result',
          data: '{"result":"旧版一行译文"}',
        ),
      );

      final result = (event as SentenceAiResultEvent).result!;
      expect(result.translation, '旧版一行译文');
    });

    test('fallback text is kept for one-line answers', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'result',
          data: '{"fallback":true,"text":"纯文本译文"}',
        ),
      );

      final result = event as SentenceAiResultEvent;
      expect(result.fallbackText, '纯文本译文');
    });

    test('meta carries cache information', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'meta',
          data: '{"cached":true,"provider":"openai","model":"m"}',
        ),
      );

      final meta = event as SentenceAiMetaEvent;
      expect(meta.cached, isTrue);
      expect(meta.provider, 'openai');
    });

    test('error keeps the readable kind and message', () {
      final event = parseSentenceAiEvent(
        const SseEvent(
          event: 'error',
          data: '{"kind":"rate","message":"slow down"}',
        ),
      );

      final error = event as SentenceAiErrorEvent;
      expect(error.kind, 'rate');
      expect(error.message, 'slow down');
    });
  });

  group('SentenceAiService', () {
    test('decodes a chunked SSE stream into typed events', () async {
      final stream = _bytes([
        ': heartbeat\n\n',
        'event: meta\n',
        'data: {"cached":false,"provider":"openai","model":"gpt-4o-mini"}\n\n',
        'event: text\n',
        'data: {"text":"Hello"}\n\n',
        'event: result\n',
        'data: {"result":{"translation":"你好",'
            '"segments":[{"part":"Hello","meaning":"你好","role":"感叹"}],'
            '"grammar":[{"point":"问候","explanation":"打招呼","fragment":"Hello"}],'
            '"context":"见面时的问候。",'
            '"examples":[{"source":"Hello there.","translation":"你好呀。"}]}}\n\n',
        'event: done\n',
        'data: {}\n\n',
      ]);

      final events = await SentenceAiService(
        _apiWith(stream),
      ).analyze(sentence: 'Hello', langId: 2).toList();

      expect(events.map((e) => e.runtimeType), [
        SentenceAiMetaEvent,
        SentenceAiTextEvent,
        SentenceAiResultEvent,
        SentenceAiDoneEvent,
      ]);

      final result = (events[2] as SentenceAiResultEvent).result!;
      expect(result.translation, '你好');
      expect(result.segments.single.meaning, '你好');
      expect(result.grammar.single.point, '问候');
      expect(result.context, '见面时的问候。');
      expect(result.examples.single.source, 'Hello there.');
    });

    test('a raw one-line body (pre-upgrade server) becomes a result', () async {
      final events = await SentenceAiService(
        _apiWith(_bytes(['一行旧译文'])),
      ).analyze(sentence: 'Hello', langId: 1).toList();

      final result = (events.single as SentenceAiResultEvent).result!;
      expect(result.translation, '一行旧译文');
    });

    test('a raw JSON body becomes a structured result without SSE', () async {
      final events = await SentenceAiService(
        _apiWith(_bytes(['{"translation":"JSON 译文","context":"ctx"}'])),
      ).analyze(sentence: 'Hello', langId: 1).toList();

      final result = (events.single as SentenceAiResultEvent).result!;
      expect(result.translation, 'JSON 译文');
      expect(result.context, 'ctx');
    });

    test('text-only SSE falls back to the streamed translation', () async {
      final events = await SentenceAiService(
        _apiWith(
          _bytes([
            'event: text\n',
            'data: {"text":"流式"}\n\n',
            'event: text\n',
            'data: {"text":"译文"}\n\n',
            'event: done\n',
            'data: {}\n\n',
          ]),
        ),
      ).analyze(sentence: 'Hello', langId: 1).toList();

      expect(
        events.whereType<SentenceAiTextEvent>().map((e) => e.text).join(),
        '流式译文',
      );
      expect(events.last, isA<SentenceAiDoneEvent>());
    });
  });
}

ApiService _apiWith(Stream<Uint8List> stream) {
  final dio = Dio();
  dio.httpClientAdapter = _StreamAdapter(stream);
  return ApiService(baseUrl: 'http://test.local', dio: dio);
}

Stream<Uint8List> _bytes(List<String> parts) {
  final bytes = Uint8List.fromList(utf8.encode(parts.join()));
  final chunks = <Uint8List>[];
  const chunkSize = 11;
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
