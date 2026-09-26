// Contract tests for the page-level read-aloud player's Loop and Auto-pause
// modes.
//
// These pin the behaviours the web player has, because the two are meant to
// match and a silent divergence is easy to ship:
//
//   * Loop repeats the sentence the playhead is on -- it does not step to the
//     next sentence when the sentence ends.
//   * Auto-pause stops at the end of the sentence and rewinds to its start,
//     so pressing play reads the *same* sentence again.
//   * Loop wins when both are on.
//   * Turning loop on while auto-paused resumes immediately ("press loop to
//     keep looping").
//   * A sentence the service cannot voice must not pin the loop: the 422
//     fragment path turns an unvoiceable cue into an instant completion, and
//     looping that would spin with no audio and no way out.

import 'dart:async';
import 'dart:convert';
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

/// A TTS service whose utterances finish after a controllable delay, so the
/// loop / auto-pause paths can be driven without waiting on real audio.
class FakeTtsService implements TTSService {
  FakeTtsService({
    this.audioMs = 300,
    this.fetchMs = 0,
    this.stopEventDelayMs = 0,
    this.refuseToVoice = const {},
    this.supportsBytes = false,
  });

  /// Whether the service offers byte output.

  /// Off by default: these tests pin the loop and auto-pause behaviour, and
  /// turning byte output on moves them onto the prefetch path -- a different
  /// code route the prefetch test covers on its own. The bytes carry the text
  /// so either path can be asserted on.
  final bool supportsBytes;

  /// How long one utterance "plays" before reporting completion.
  ///
  /// Keep this above [TTSPlayerNotifier]'s instant-completion threshold for
  /// the normal cases, or the player reads every sentence as one the service
  /// never voiced.
  final int audioMs;

  /// How long [speak] takes to get going, standing in for the network fetch
  /// the real services do before any audio starts.
  final int fetchMs;

  /// How long after [stop] the `stopped` event lands.  The real player reports
  /// it from the platform side, so it arrives after the caller has already
  /// moved on.
  final int stopEventDelayMs;

  /// Texts the service refuses to voice, mirroring the server's 422 for a
  /// fragment edge-tts will not synthesize.
  final Set<String> refuseToVoice;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  final List<String> spoken = [];

  /// Sentences played from prefetched bytes rather than fetched on demand.
  final List<String> spokenFromBytes = [];
  Timer? _playingTimer;
  double? lastRate;
  bool disposed = false;

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => supportsBytes;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    final trimmed = text.trim();
    if (refuseToVoice.contains(trimmed)) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }
    return Uint8List.fromList(utf8.encode(trimmed));
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    // The bytes are the text, so the same events play out whichever way the
    // player got the audio -- the difference under test is only the timing.
    final text = utf8.decode(bytes);
    spokenFromBytes.add(text);
    await speak(text);
  }

  @override
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    spoken.add(trimmed);

    if (refuseToVoice.contains(trimmed)) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }

    _playingTimer?.cancel();
    if (fetchMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: fetchMs));
    }
    _stateCtl.add(PlayerState.playing);
    _playingTimer = Timer(Duration(milliseconds: audioMs), () {
      if (!disposed) _stateCtl.add(PlayerState.completed);
    });
  }

  @override
  Future<void> stop() async {
    // Stopping cancels the pending end-of-utterance, exactly as a real player
    // does, and reports the stop -- late, like the platform side does.
    _playingTimer?.cancel();
    _playingTimer = null;
    if (stopEventDelayMs > 0) {
      Timer(Duration(milliseconds: stopEventDelayMs), () {
        if (!disposed) _stateCtl.add(PlayerState.stopped);
      });
    } else {
      _stateCtl.add(PlayerState.stopped);
    }
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    lastRate = rate;
  }

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
/// disposed -- a "no rate configured" state, which is what a fresh install
/// has anyway.
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

/// One utterance plus the completion event it schedules.
const Duration _utterance = Duration(milliseconds: 300);

void main() {
  // The player reads the TTS settings to seed its rate, and that provider
  // loads SharedPreferences -- which needs the binding and a backing store
  // under `flutter test`.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('loop repeats the sentence instead of advancing', () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.toggleLoopMode();
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    final state = container.read(ttsPlayerProvider);
    expect(state.loopMode, isTrue);
    expect(
      fake.spoken.length,
      greaterThanOrEqualTo(2),
      reason: 'loop should have restarted the sentence; spoke ${fake.spoken}',
    );
    expect(
      fake.spoken.every((s) => s == 'あ'),
      isTrue,
      reason: 'only the current sentence may be read; spoke ${fake.spoken}',
    );
    expect(
      state.currentIndex,
      0,
      reason: 'loop must not step to the next sentence',
    );
  });

  test('auto-pause rewinds to the sentence start and play() reads it again',
      () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    notifier.toggleAutoPauseMode();
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    var state = container.read(ttsPlayerProvider);
    expect(
      state.status,
      TTSPlayerStatus.paused,
      reason: 'auto-pause must stop at the end of the sentence',
    );
    expect(state.currentIndex, 0);
    expect(
      state.positionInSnippet,
      Duration.zero,
      reason: 'the sentence is rewound so pressing play repeats it',
    );

    final utterancesBefore = fake.spoken.length;
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    state = container.read(ttsPlayerProvider);
    expect(
      state.currentIndex,
      0,
      reason: 'resuming must read the same sentence, not the next one',
    );
    expect(
      fake.spoken.length,
      greaterThan(utterancesBefore),
      reason: 'pressing play should have spoken again',
    );
    expect(fake.spoken.last, 'あ');
  });

  test('loop wins when auto-pause is on too', () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    notifier.toggleAutoPauseMode();
    await notifier.toggleLoopMode();
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    final state = container.read(ttsPlayerProvider);
    expect(state.loopMode, isTrue);
    expect(state.autoPauseMode, isTrue);
    expect(
      state.status,
      isNot(TTSPlayerStatus.paused),
      reason: 'loop takes precedence, so it must not settle on a pause',
    );
    expect(
      fake.spoken.every((s) => s == 'あ'),
      isTrue,
      reason: 'spoke ${fake.spoken}',
    );
  });

  test('turning loop on while auto-paused resumes the sentence', () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    notifier.toggleAutoPauseMode();
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      container.read(ttsPlayerProvider).status,
      TTSPlayerStatus.paused,
      reason: 'precondition: auto-pause has fired',
    );

    await notifier.toggleLoopMode();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(ttsPlayerProvider).status,
      isNot(TTSPlayerStatus.paused),
      reason: 'pressing loop should start looping without another press of play',
    );
  });

  test('loop gives up on a sentence the service cannot voice', () async {
    final fake = FakeTtsService(
      audioMs: _utterance.inMilliseconds,
      refuseToVoice: {'」'},
    );
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['」', 'あ', 'い']));
    await notifier.toggleLoopMode();
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final state = container.read(ttsPlayerProvider);
    final attempts = fake.spoken.where((s) => s == '」').length;
    expect(
      attempts,
      lessThanOrEqualTo(4),
      reason: 'an unvoiceable cue must not spin; spoke ${fake.spoken}',
    );
    expect(
      state.currentIndex,
      greaterThan(0),
      reason: 'the player must move past a cue it cannot voice',
    );
  });

  test('a rate change re-estimates the timeline and reaches the service',
      () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あいうえお']));
    final before = container.read(ttsPlayerProvider).totalDuration;

    await notifier.setPlaybackRate(2.0);
    final after = container.read(ttsPlayerProvider).totalDuration;
    expect(container.read(ttsPlayerProvider).playbackRate, 2.0);
    expect(
      after,
      lessThan(before),
      reason: 'reading twice as fast should shorten the estimate '
          '($before -> $after)',
    );

    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      fake.lastRate,
      2.0,
      reason: 'the player must hand the chosen rate to the service',
    );
  });

  test('rate is clamped to the web player range and resets to the settings',
      () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あいうえお']));

    await notifier.setPlaybackRate(9.0);
    expect(container.read(ttsPlayerProvider).playbackRate, 2.0);

    await notifier.setPlaybackRate(0.1);
    expect(container.read(ttsPlayerProvider).playbackRate, 0.5);

    // The default settings carry no rate, so a reset lands on 1.0.
    await notifier.resetPlaybackRate();
    expect(container.read(ttsPlayerProvider).playbackRate, 1.0);
  });

  test('jumping a sentence moves exactly one sentence', () async {
    // The stop we issue to leave the current sentence reports `stopped` late,
    // landing while the next sentence is still being fetched.  Read as "that
    // sentence finished" it advances a second time -- the bug that made "next
    // sentence" skip two.
    final fake = FakeTtsService(
      audioMs: 600,
      fetchMs: 80,
      stopEventDelayMs: 10,
    );
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う', 'え']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      container.read(ttsPlayerProvider).currentIndex,
      0,
      reason: 'precondition: still reading the first sentence',
    );

    await notifier.next();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      container.read(ttsPlayerProvider).currentIndex,
      1,
      reason: 'the late stop event must not be read as a finished sentence',
    );
  });

  test('a new page keeps the loop and auto-pause choices', () async {
    final fake = FakeTtsService(audioMs: _utterance.inMilliseconds);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い']));
    await notifier.toggleLoopMode();
    notifier.toggleAutoPauseMode();

    notifier.loadPage(_page(['う', 'え']));

    final state = container.read(ttsPlayerProvider);
    expect(state.loopMode, isTrue);
    expect(state.autoPauseMode, isTrue);
    expect(state.snippets, hasLength(2));
  });
}
