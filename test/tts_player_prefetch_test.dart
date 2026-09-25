// Why read-aloud "stops after every sentence" on mobile while the web player
// flows straight through.
//
// The web player hands each sentence to the browser's own synthesiser, with
// the text already on the page, so nothing is fetched once reading starts.
// A networked mobile service has no such luxury: `speak()` pays one HTTP
// request -- plus synthesis, when the server's cache misses -- before there
// is any audio to play, and that wait landed squarely between two sentences.
//
// The fix is to fetch sentence N+1 while sentence N is being read, then hand
// the bytes straight to the platform player. Pinned here:
//   * the fetch no longer falls into the gap between sentences;
//   * a service that cannot produce bytes keeps the old behaviour, intact
//     rather than broken, and the gap comes back (proof the gain above is
//     real, not a slack assertion);
//   * a prefetch that fails is nobody's problem but its own -- the sentence
//     is fetched on demand and reads exactly as it used to;
//   * when the network is slower than the sentences are long, prefetching
//     simply stops helping rather than breaking the read.
//
// Timings below use a longer sentence than fetch on purpose. That is the real
// shape of the problem -- a spoken sentence lasts seconds, a request takes a
// fraction of one -- and it is also the only regime where prefetching can
// help at all: for it to land, sentence N+1's bytes must arrive before
// sentence N stops talking.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lute_for_mobile/core/network/tts_service.dart';
import 'package:lute_for_mobile/core/providers/tts_provider.dart';
import 'package:lute_for_mobile/features/reader/providers/tts_player_provider.dart';
import 'package:lute_for_mobile/features/settings/models/tts_settings.dart';
import 'package:lute_for_mobile/features/settings/providers/tts_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long one spoken sentence lasts, and how long fetching it takes. See
/// the note above: the fetch has to be the shorter of the two for any of this
/// to matter.
const int _audioMs = 400;
const int _fetchMs = 150;

class _FetchingTtsService implements TTSService {
  _FetchingTtsService({
    required this.audioMs,
    required this.fetchMs,
    this.supportsBytes = true,
    this.failPrefetchOn,
  });

  final int audioMs;
  final int fetchMs;
  final bool supportsBytes;

  /// Text whose prefetch fails, standing in for a 422 fragment or a blip in
  /// the connection. Only the prefetch fails; speaking it still works.
  final String? failPrefetchOn;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  Timer? _playingTimer;
  bool disposed = false;

  /// Sentences that had to be fetched before anything could be heard.
  final List<String> fetchedNow = [];

  /// Sentences played from bytes that were already in hand.
  final List<String> playedFromPrefetch = [];

  /// When each sentence started making sound, for measuring the gaps.
  final List<DateTime> startedPlaying = [];

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => supportsBytes;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    await Future<void>.delayed(Duration(milliseconds: fetchMs));
    if (text.trim() == failPrefetchOn) {
      throw TTSException('simulated prefetch failure');
    }
    return Uint8List.fromList(utf8.encode(text.trim()));
  }

  @override
  Future<void> speak(String text) async {
    fetchedNow.add(text.trim());
    await Future<void>.delayed(Duration(milliseconds: fetchMs));
    _startPlaying();
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    playedFromPrefetch.add(utf8.decode(bytes));
    _startPlaying();
  }

  void _startPlaying() {
    _playingTimer?.cancel();
    startedPlaying.add(DateTime.now());
    _stateCtl.add(PlayerState.playing);
    _playingTimer = Timer(Duration(milliseconds: audioMs), () {
      if (!disposed) _stateCtl.add(PlayerState.completed);
    });
  }

  @override
  Future<void> stop() async {
    _playingTimer?.cancel();
    _playingTimer = null;
    _stateCtl.add(PlayerState.stopped);
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

/// Answers synchronously; the real one loads SharedPreferences, and leaving
/// that in flight past a test's container would be noise here. A fresh
/// install has no rate configured either, which is what this reports.
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

/// Gap between two consecutive sentences starting to make sound.
int _gapBetween(List<DateTime> starts, int first) =>
    starts[first + 1].difference(starts[first]).inMilliseconds;

/// A gap that still contains the fetch, versus one that does not. Anything at
/// or past this threshold waited for the network between sentences.
final _gapWithFetch = _audioMs + _fetchMs - 50;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the next sentence starts as soon as the previous one ends', () async {
    final fake = _FetchingTtsService(audioMs: _audioMs, fetchMs: _fetchMs);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    expect(
      fake.startedPlaying.length,
      greaterThanOrEqualTo(3),
      reason: 'the page should have read all three sentences; '
          'started ${fake.startedPlaying.length}',
    );
    expect(
      fake.playedFromPrefetch,
      ['い', 'う'],
      reason: 'every sentence after the first should come from prefetched '
          'audio; only the first has nothing ahead of it to fetch',
    );
    expect(
      fake.fetchedNow,
      ['あ'],
      reason: 'only the opening sentence should have paid for a fetch',
    );

    expect(
      _gapBetween(fake.startedPlaying, 0),
      lessThan(_gapWithFetch),
      reason: 'the fetch must not fall into the gap between sentences; got '
          '${_gapBetween(fake.startedPlaying, 0)} ms for a $_fetchMs ms fetch, '
          'cutoff $_gapWithFetch ms',
    );
    expect(
      _gapBetween(fake.startedPlaying, 1),
      lessThan(_gapWithFetch),
      reason: 'the same must hold for every following pair',
    );
  });

  test('a service with no byte output still waits between sentences',
      () async {
    // The control: identical timings, byte output off, so nothing can be
    // prefetched. Whatever the gap measures here is what the fix removed.
    final fake = _FetchingTtsService(
      audioMs: _audioMs,
      fetchMs: _fetchMs,
      supportsBytes: false,
    );
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    expect(fake.startedPlaying.length, greaterThanOrEqualTo(2));
    expect(
      fake.playedFromPrefetch,
      isEmpty,
      reason: 'nothing can be prefetched from a service with no byte output',
    );
    expect(
      _gapBetween(fake.startedPlaying, 0),
      greaterThanOrEqualTo(_gapWithFetch),
      reason: 'the whole fetch lands between the two sentences',
    );
  });

  test('a failed prefetch is invisible: the sentence is fetched instead',
      () async {
    final fake = _FetchingTtsService(
      audioMs: _audioMs,
      fetchMs: _fetchMs,
      failPrefetchOn: 'い',
    );
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    final state = container.read(ttsPlayerProvider);
    expect(
      state.status,
      isNot(TTSPlayerStatus.error),
      reason: 'a prefetch failure is not the listener\'s problem; '
          'message: ${state.errorMessage}',
    );
    expect(state.errorMessage, isNull);
    expect(
      fake.fetchedNow,
      contains('い'),
      reason: 'the sentence whose prefetch failed must be fetched on demand, '
          'not skipped',
    );
    expect(
      fake.startedPlaying.length,
      greaterThanOrEqualTo(3),
      reason: 'the page should still read all three sentences through',
    );
  });

  test('a fetch slower than a sentence costs nothing but the benefit',
      () async {
    // Inverted timings: every request outlasts a sentence, so the prefetch
    // can never arrive in time and every sentence is fetched on demand. It
    // must degrade to the old behaviour, not to a stutter or an error -- this
    // is what a very slow link or a cold server cache looks like.
    final fake = _FetchingTtsService(audioMs: 100, fetchMs: 300);
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page(['あ', 'い', 'う']));
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    final state = container.read(ttsPlayerProvider);
    expect(state.status, isNot(TTSPlayerStatus.error));
    expect(state.errorMessage, isNull);
    expect(
      fake.startedPlaying.length,
      greaterThanOrEqualTo(2),
      reason: 'the page must keep reading even though no prefetch landed',
    );
    expect(
      fake.fetchedNow.take(fake.startedPlaying.length).toList(),
      hasLength(fake.startedPlaying.length),
      reason: 'every sentence read here had to be fetched',
    );
  });
}
