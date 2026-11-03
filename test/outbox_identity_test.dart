import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/content_service.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/outbox_service.dart';
import 'package:song_mobile/core/outbox/outbox_store.dart';

class _RecordingContent implements ContentService {
  final List<int> edits = [];

  @override
  Future<void> editTerm(
    int termId,
    Map<String, dynamic> data, {
    bool bypassQueue = false,
  }) async {
    edits.add(termId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('outbox identity isolation', () {
    test('A 的意图不会在 B 登录后被重放，也不会出现在 B 的面板里', () async {
      var identity = 'https://srv|alice';
      final content = _RecordingContent();
      final service = OutboxService(
        store: InMemoryOutboxStore(),
        content: content,
        identity: () => identity,
      );

      await service.enqueueTermStatus(
        7,
        '3',
        formData: {'term': '猫', 'translation': 'cat'},
      );
      expect(service.intents, hasLength(1));

      identity = 'https://srv|bob';
      expect(
        service.intents,
        isEmpty,
        reason: 'the queue panel must not show another account\'s term text',
      );

      await service.flush();
      expect(
        content.edits,
        isEmpty,
        reason: 'term ids are per-account; replaying would edit B\'s term 7',
      );

      identity = 'https://srv|alice';
      expect(service.intents, hasLength(1));
      await service.flush();
      expect(content.edits, [7], reason: 'A gets its pending edit back');
    });

    test('legacy owner-less intents are adopted to the starting identity', () async {
      final store = InMemoryOutboxStore();
      final service = OutboxService(
        store: store,
        content: _RecordingContent(),
        identity: () => 'https://srv|alice',
      );

      service.seed({
        'term:7': TermEditIntent(termId: 7, status: '3', seq: 1).encode(),
      });
      // seed rewrites the record to the scoped key without awaiting (it runs
      // inside a Riverpod build).
      await Future<void>.delayed(Duration.zero);

      expect(service.intents.single.coalesceKey, 'https://srv|alice|term:7');
      final raw = await store.readAll();
      expect(raw.keys, contains('https://srv|alice|term:7'));
      expect(raw.keys, isNot(contains('term:7')));
    });
  });
}
