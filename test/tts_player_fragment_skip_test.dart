// Diagnostic test for the page-level read-aloud player's behaviour around a
// sentence the server cannot synthesize (the `」` fragment, which edge-tts
// refuses to voice).
//
// Contract, as of EdgeTTSService's current design:
//   * EdgeTTSService.speak() RETHROWS TTSUnpronounceableFragmentException
//     rather than faking a PlayerState.completed, because a synthetic event can
//     be dropped when the caller re-subscribes between emit and delivery.
//   * TTSPlayerNotifier._speakCurrent() catches it and treats it as a
//     completion, so the page keeps reading.
//   * Anything else stays a real error: the player must stop and say so, not
//     silently run through the rest of the page.
//
// The second and third tests below lock in that boundary -- swallowing every
// failure would look "fixed" while quietly reading nothing.

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/core/network/tts_service.dart';
import 'package:lute_for_mobile/core/providers/tts_provider.dart';
import 'package:lute_for_mobile/features/reader/providers/tts_player_provider.dart';
import 'package:lute_for_mobile/features/settings/models/tts_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mimics EdgeTTSService: byte-based output, normal sentences finish after a
/// short "playback", and the unpronounceable fragment is reported as an
/// exception (never as a fabricated stream event).
class FakeEdgeTTSService implements TTSService {
  FakeEdgeTTSService({
    this.fragment = '」',
    this.audioMs = 30,
    this.failGenericOn,
  });

  final String fragment;
  final int audioMs;

  /// A sentence that fails with a *non*-fragment error (a real outage).
  final String? failGenericOn;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  final List<String> spoken = [];
  bool disposed = false;

  /// Rate the player last asked for, so a test can assert the player bar's
  /// rate control actually reaches the service.
  double? lastRate;

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    if (text.trim() == fragment) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }
    return Uint8List.fromList(List.filled(16, 0));
  }

  @override
  Future<void> speak(String text) async {
    if (disposed) throw StateError('speak() on a disposed service');
    final trimmed = text.trim();
    spoken.add(trimmed);

    if (trimmed == fragment) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }
    if (trimmed == failGenericOn) {
      throw TTSException('Edge TTS request failed: simulated outage');
    }

    _stateCtl.add(PlayerState.playing);
    Timer(Duration(milliseconds: audioMs), () {
      if (!disposed) _stateCtl.add(PlayerState.completed);
    });
  }

  @override
  Future<void> stop() async {
    _stateCtl.add(PlayerState.stopped);
  }

  @override
  Future<void> setLanguage(String languageCode) async {}

  @override
  Future<void> setPlaybackRate(double rate) async {
    lastRate = rate;
  }

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async => [];

  @override
  void dispose() {
    disposed = true;
    _stateCtl.close();
  }
}

class _FakeTTSNotifier extends TTSNotifier {
  _FakeTTSNotifier(this.svc);
  final TTSService svc;

  @override
  TTSService build() => svc;
}

/// 33 sentences; index 6 is the unpronounceable `」`, matching the real book
/// 《横浜のアパートの惨劇》.
List<TTSPlayerSentence> _page({String? failGenericOn}) {
  final texts = <String>[
    '【一】',
    '日の暮れ、私は横浜に行きました。',
    '香山さんの古いアパートを訪ねました。',
    '部屋の空気はとても冷たいです。',
    '香山さんは冷たく笑いました。',
    '「私の趣味を見せましょう。',
    '」',
    '私は部屋の中を見回しました。',
    '壁には古い絵が掛かっています。',
    '窓の外は雨でした。',
  ];
  while (texts.length < 33) {
    texts.add('文番号${texts.length}のサンプル文です。');
  }
  if (failGenericOn != null) texts[3] = failGenericOn;
  return [
    for (var i = 0; i < texts.length; i++)
      TTSPlayerSentence(sentenceId: i, text: texts[i]),
  ];
}

ProviderContainer _containerFor(TTSService fake) => ProviderContainer(
  overrides: [ttsServiceProvider.overrideWith(() => _FakeTTSNotifier(fake))],
);

void main() {
  // The player reads the TTS speed setting to estimate cue durations, and that
  // provider loads SharedPreferences -- which needs the binding and a backing
  // store under `flutter test`.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('page player advances past an unpronounceable fragment', () async {
    final fake = FakeEdgeTTSService();
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final transitions = <String>[];
    container.listen(ttsPlayerProvider, (prev, next) {
      if (prev?.currentIndex != next.currentIndex ||
          prev?.status != next.status) {
        transitions.add('idx=${next.currentIndex} ${next.status.name}');
      }
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page());
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final state = container.read(ttsPlayerProvider);
    expect(
      fake.spoken.contains(fake.fragment),
      isTrue,
      reason: 'the fragment at index 6 should have been attempted',
    );
    expect(
      transitions,
      contains('idx=7 loading'),
      reason:
          'playback must move past the fragment at index 6; it had to reach '
          'index 7. Transitions were: ${transitions.join(", ")}',
    );
    expect(
      state.errorMessage,
      isNull,
      reason: 'a skippable fragment must not raise an error banner',
    );
    expect(
      state.currentIndex,
      greaterThan(6),
      reason: 'the player must not end up parked on the fragment',
    );
  });

  test('a real failure still stops and reports', () async {
    final fake = FakeEdgeTTSService(failGenericOn: '部屋の空気はとても冷たいです。');
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(failGenericOn: '部屋の空気はとても冷たいです。'));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final state = container.read(ttsPlayerProvider);
    expect(
      state.status,
      TTSPlayerStatus.error,
      reason: 'an unexplained failure must surface as an error, not be skipped',
    );
    expect(state.errorMessage, isNotNull);
    expect(
      fake.spoken.contains('壁には古い絵が掛かっています。'),
      isFalse,
      reason: 'the player must not keep reading past a real error',
    );
  });
}
