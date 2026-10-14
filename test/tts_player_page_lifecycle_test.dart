// Contracts for the read-aloud player at page boundaries.
//
// Two behaviours a reader feels immediately, both about what "play" means
// once the page has moved on:
//
//   * Reading a page to the end leaves the player ready to start over --
//     the next press of play reads the FIRST sentence again.  It used to
//     leave the playhead on the last sentence, so that press either re-read
//     it or, when the platform would not replay the audio that had just
//     finished, did nothing at all.
//   * Loading a new page stops the audio still sounding.  It belongs to the
//     page being left: its sentences are gone from the cue list and its
//     completion events are no longer subscribed, so without an explicit
//     stop it would just hang there until the user pressed stop.
//
// The second one is what keeps "turn the page while reading" honest: the
// page in front of the reader and the voice must never disagree.

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/tts_service.dart';
import 'package:song_mobile/core/providers/tts_provider.dart';
import 'package:song_mobile/features/reader/providers/tts_player_provider.dart';
import 'package:song_mobile/features/settings/models/tts_settings.dart';
import 'package:song_mobile/features/settings/providers/tts_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A TTS service whose utterances finish after a fixed delay and report
/// completion like a real player.  No byte output on purpose: both contracts
/// under test live on the plain speak() path, which is also what a fresh
/// first sentence uses on a real Edge TTS service.
class _FakeTtsService implements TTSService {
  _FakeTtsService({this.audioMs = 300});

  /// How long one utterance "plays" before reporting completion.  Above the
  /// player's instant-completion threshold, so an utterance counts as really
  /// voiced.
  final int audioMs;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  final List<String> spoken = [];
  int stopCalls = 0;
  Timer? _playingTimer;
  bool disposed = false;

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => false;

  @override
  Future<Uint8List> getAudioBytes(String text) async =>
      throw UnimplementedError('no byte output in this fake');

  @override
  Future<void> speakBytes(Uint8List bytes) async =>
      throw UnimplementedError('no byte output in this fake');

  @override
  Future<void> speak(String text) async {
    spoken.add(text.trim());
    _playingTimer?.cancel();
    _playingTimer = Timer(Duration(milliseconds: audioMs), () {
      if (!disposed) _stateCtl.add(PlayerState.completed);
    });
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    // Stopping cancels the pending end-of-utterance, exactly as a real
    // player does: a stopped sentence never reports completion.
    _playingTimer?.cancel();
    _playingTimer = null;
  }

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  Future<void> setLanguage(String languageCode) async {}

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

class _FakeTtsNotifier extends TTSNotifier {
  _FakeTtsNotifier(this.svc);
  final TTSService svc;

  @override
  TTSService build() => svc;
}

/// The player seeds its rate from the TTS settings before its first page is
/// loaded, and the real notifier fills those settings in from
/// SharedPreferences asynchronously.  This stub answers synchronously so the
/// short tests here do not leave that load in flight when the container is
/// disposed.
class _StubTtsSettings extends TTSSettingsNotifier {
  @override
  TTSSettings build() => const TTSSettings(
    provider: TTSProvider.none,
    providerConfigs: {TTSProvider.none: TTSSettingsConfig()},
  );
}

ProviderContainer _containerFor(TTSService fake) => ProviderContainer(
  overrides: [
    ttsServiceProvider.overrideWith(() => _FakeTtsNotifier(fake)),
    ttsSettingsProvider.overrideWith(_StubTtsSettings.new),
  ],
);

List<TTSPlayerSentence> _page(List<String> texts) => [
  for (var i = 0; i < texts.length; i++)
    TTSPlayerSentence(sentenceId: i, text: texts[i]),
];

/// Three utterances plus their completion events, with margin.
const Duration _wholePage = Duration(milliseconds: 1100);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('after reading to the end, play starts the page over', () async {
    final fake = _FakeTtsService(audioMs: 300);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.play();
    await Future<void>.delayed(_wholePage);

    var state = container.read(ttsPlayerProvider);
    expect(
      state.status,
      TTSPlayerStatus.idle,
      reason: 'the page has been read to the end',
    );
    expect(fake.spoken, ['あ', 'い', 'う']);
    expect(
      state.currentIndex,
      -1,
      reason: 'the playhead returns to "not started", like a fresh page',
    );
    expect(state.position, Duration.zero);

    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    state = container.read(ttsPlayerProvider);
    expect(
      state.currentIndex,
      0,
      reason: 'pressing play after the end reads the page again from the top',
    );
    expect(
      fake.spoken.last,
      'あ',
      reason: 'spoke ${fake.spoken}',
    );
  });

  test('loading a new page stops the audio still playing', () async {
    final fake = _FakeTtsService(audioMs: 600);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      container.read(ttsPlayerProvider).status,
      TTSPlayerStatus.playing,
      reason: 'precondition: the first sentence is being read',
    );

    // 翻页：reader 用新一页的句子表调 loadPage。
    notifier.loadPage(_page(['う', 'え', 'お']));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(ttsPlayerProvider);
    expect(
      fake.stopCalls,
      greaterThanOrEqualTo(1),
      reason: 'the old page is still sounding and must be stopped',
    );
    expect(state.status, TTSPlayerStatus.idle);
    expect(state.currentIndex, -1);
    expect(state.snippets, hasLength(3));

    // 旧页剩下的句子不许被继续念下去：完成事件已随退订不再到来，
    // 声音也被停掉 —— 两者都要成立，缺一个就是「音频与可见页面吵架」。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      fake.spoken,
      ['あ'],
      reason: 'nothing more of the old page may be read; spoke ${fake.spoken}',
    );
  });
}
