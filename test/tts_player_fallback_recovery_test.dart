// Contracts for how the read-aloud player *recovers* from the on-device
// fallback.  The fallback itself (what triggers it, what the banner says) is
// pinned by tts_player_fragment_skip_test; this file pins the way out:
//
//   * The banner ("服务端连续念不出来，已切到本地语音") is a statement about
//     the *present*, not a scar.  Once the server voices a sentence again,
//     the banner must be gone.  Two doors lead back to the server:
//       - pressing play again (an explicit user retry; stop() and page loads
//         already reset the fallback, play() was the missing one), and
//       - the book's language arriving late (the cold-start race: the cue
//         list was loaded before the shelf answered, the first sentences were
//         refused under the fallback `en` tag, and the player degraded.  When
//         the real language finally resolves, the refusal/degradation state
//         must be cleared so the next sentence retries the server).
//
//   * The degradation is per listening session: recovery must happen without
//     a stop() or a page load in between.  seekTo() is used in the second
//     test precisely because it does *not* reset the fallback state -- if the
//     next sentence reaches the server fake, the reset came from the fix.

import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/tts_service.dart';
import 'package:song_mobile/core/providers/tts_provider.dart';
import 'package:song_mobile/features/reader/providers/current_book_provider.dart';
import 'package:song_mobile/features/reader/providers/tts_player_provider.dart';
import 'package:song_mobile/features/settings/models/tts_settings.dart';
import 'package:song_mobile/features/settings/providers/tts_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real EdgeTTSService subclass so `primary is EdgeTTSService` inside the
/// notifier holds and the escalation path is exercised for real.  Its
/// constructor only wires an AudioPlayer and a Dio; both platform channels are
/// mocked out below, and every TTSService member is overridden with
/// pure-Dart behaviour.
class _RecoveringEdgeService extends EdgeTTSService {
  _RecoveringEdgeService() : super(serverUrl: 'http://127.0.0.1:1');

  /// False once "the server has recovered": sentences are refused (422-style)
  /// until then.
  bool refusing = true;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  final List<String> spoken = [];
  bool disposed = false;

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => false;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    final t = text.trim();
    if (refusing) throw TTSUnpronounceableFragmentException('refused');
    return Uint8List.fromList(utf8.encode(t));
  }

  @override
  Future<void> speakBytes(Uint8List bytes) => speak(utf8.decode(bytes));

  @override
  Future<void> speak(String text) async {
    if (disposed) throw StateError('speak() on a disposed service');
    final t = text.trim();
    spoken.add(t);
    if (refusing) throw TTSUnpronounceableFragmentException('refused');
    Timer(const Duration(milliseconds: 40), () {
      if (!disposed && !_stateCtl.isClosed) {
        _stateCtl.add(PlayerState.completed);
      }
    });
  }

  @override
  Future<void> stop() async {}

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
    // 故意不调 super.dispose()：基类会 close 它自己的事件控制器，而其
    // AudioPlayer 的迟到状态事件仍会往里 add（Cannot add after close），
    // 测试区直接爆未处理异常。测试 fake 只关自己的流。
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

class _StubTtsSettings extends TTSSettingsNotifier {
  @override
  TTSSettings build() => const TTSSettings(
    provider: TTSProvider.edgeTTS,
    providerConfigs: {TTSProvider.edgeTTS: TTSSettingsConfig()},
  );
}

ProviderContainer _containerFor(_RecoveringEdgeService fake) =>
    ProviderContainer(
      overrides: [
        ttsServiceProvider.overrideWith(() => _FakeTTSNotifier(fake)),
        ttsSettingsProvider.overrideWith(_StubTtsSettings.new),
      ],
    );

List<TTSPlayerSentence> _page(List<String> texts) => [
  for (var i = 0; i < texts.length; i++)
    TTSPlayerSentence(sentenceId: i, text: texts[i]),
];

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Drives the player into the degraded state: three distinct sentences
/// refused -> escalation -> on-device voice + fallback banner.  Returns once
/// the banner is up.
Future<void> _reachDegradedState(ProviderContainer container) async {
  final notifier = container.read(ttsPlayerProvider.notifier);
  notifier.loadPage(_page(['いち', 'に', 'さん', 'よん']));
  unawaited(notifier.play());
  await _waitUntil(
    () => container.read(ttsPlayerProvider).fallbackNotice != null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // EdgeTTSService's constructor wires an AudioPlayer; OnDeviceTTSService's
    // constructor talks to flutter_tts.  Neither may hit a real platform
    // channel under `flutter test`.
    final binding = TestDefaultBinaryMessengerBinding.instance;
    Future<Object?> nullHandler(MethodCall call) async => null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      nullHandler,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      nullHandler,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      nullHandler,
    );
  });

  test('服务端恢复后，再按播放撤掉降级横幅并回到服务端语音', () async {
    final edge = _RecoveringEdgeService();
    final container = _containerFor(edge);
    addTearDown(() {
      container.dispose();
      edge.dispose();
    });

    await _reachDegradedState(container);
    var state = container.read(ttsPlayerProvider);
    expect(
      state.fallbackNotice,
      isNotNull,
      reason: 'precondition: the escalation banner is up',
    );
    expect(
      state.status,
      TTSPlayerStatus.playing,
      reason: 'precondition: the degraded page keeps reading (on-device)',
    );

    // 服务端恢复，用户再按播放。
    edge.refusing = false;
    final spokenBefore = edge.spoken.length;
    await container.read(ttsPlayerProvider.notifier).play();
    await _waitUntil(() => edge.spoken.length > spokenBefore);

    state = container.read(ttsPlayerProvider);
    expect(
      state.fallbackNotice,
      isNull,
      reason: 'the banner describes the present, not the past -- the server '
          'just voiced a sentence again',
    );
    expect(
      edge.spoken[spokenBefore],
      'さん',
      reason: 'the degraded session was parked on the 3rd sentence; play '
          'resumed there, on the server voice (spoken: ${edge.spoken})',
    );
  });

  test('书的语言晚到时撤掉降级，下一句直接回服务端', () async {
    final edge = _RecoveringEdgeService();
    final container = _containerFor(edge);
    addTearDown(() {
      container.dispose();
      edge.dispose();
    });

    // 冷启动恢复阅读：书架/语言接口都还没应答，句子表先按兜底语言码装载。
    await _reachDegradedState(container);
    var state = container.read(ttsPlayerProvider);
    expect(
      state.fallbackNotice,
      isNotNull,
      reason: 'precondition: refused under the fallback tag, banner is up',
    );
    expect(state.languageResolved, isFalse);

    // 语言解析完成（书架到货触发 setBookLanguage 那条路）。
    container.read(currentBookProvider.notifier).state = const CurrentBookState(
      bookId: 1,
      langId: 2,
      languageName: 'Japanese',
    );

    state = container.read(ttsPlayerProvider);
    expect(state.languageResolved, isTrue);
    expect(state.languageTag, 'ja-JP');
    expect(
      state.fallbackNotice,
      isNull,
      reason: 'the banner names the fallback language; that language is gone',
    );

    // 降级必须真的撤销，而不只是横幅消失：seekTo 不经过 play/stop（那两条
    // 路本来就会重置降级），下一句要能直接回到服务端。
    edge.refusing = false;
    await container.read(ttsPlayerProvider.notifier).seekTo(3);
    await _waitUntil(() => edge.spoken.contains('よん'));

    expect(
      edge.spoken,
      contains('よん'),
      reason:
          'the next sentence must reach the server again; spoken: ${edge.spoken}',
    );
  });
}
