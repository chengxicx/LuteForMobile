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
//   * A *run* of fragments (3 in a row) is not a fragment.  The server answers
//     422 for every kind of synthesis failure, so a whole page that cannot be
//     voiced looks exactly like a fragment -- it must stop the player with an
//     error rather than marching silently through the page.
//   * `PlayerState.stopped` never counts as "this sentence finished".  A late
//     stop echo (or an engine error) used to land outside a 750ms window and
//     advance the playhead ahead of the audio.
//   * The page's language is handed to the player and converted to an Edge tag
//     there; a language that cannot be resolved says so on the player bar
//     instead of silently falling back to `en`.
//
// The second and third tests below lock in that boundary -- swallowing every
// failure would look "fixed" while quietly reading nothing.

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
import 'package:shared_preferences/shared_preferences.dart';

/// Mimics EdgeTTSService: byte-based output, normal sentences finish after a
/// short "playback", and the unpronounceable fragment is reported as an
/// exception (never as a fabricated stream event).
class FakeEdgeTTSService implements TTSService {
  FakeEdgeTTSService({
    this.fragment = '」',
    this.audioMs = 30,
    this.failGenericOn,
    this.supportsBytes = false,
    this.emitStrayStopBeforeComplete = false,
  });

  /// Whether the service offers byte output.

  /// Off by default so these tests keep exercising [speak], the path that
  /// carries the fragment and outage errors under test here.
  final bool supportsBytes;

  final String fragment;
  final int audioMs;

  /// A sentence that fails with a *non*-fragment error (a real outage).
  final String? failGenericOn;

  /// 一句话读到一半先发一个 `stopped`（我们自己 stop 的回声、或 on-device
  /// 引擎报错），再在念完时发 `completed`。用于钉住「`stopped` 永远不算
  /// 读完」——它以前会被时间窗漏过去，让高亮跑到音频前面。
  final bool emitStrayStopBeforeComplete;

  final _stateCtl = StreamController<PlayerState>.broadcast();
  final List<String> spoken = [];

  /// Sentences played from prefetched bytes rather than fetched on demand.
  final List<String> spokenFromBytes = [];
  bool disposed = false;

  /// Rate the player last asked for, so a test can assert the player bar's
  /// rate control actually reaches the service.
  double? lastRate;

  /// 只在第一次拒答的句子（模拟服务端偶发的 NoAudioReceived：同一 URL 重试
  /// 立刻 200 的那种）。用来钉住「单发 422 先原句重试一次再跳过」。
  final Set<String> refuseFirstAttemptOnly = {};
  final Map<String, int> _attempts = {};

  /// Whether this sentence is refused on this attempt.
  bool _refuses(String text) {
    if (text == fragment) return true;
    if (refuseFirstAttemptOnly.contains(text)) {
      final attempt = (_attempts[text] ?? 0) + 1;
      _attempts[text] = attempt;
      return attempt == 1;
    }
    return false;
  }

  @override
  Stream<PlayerState> get playerStateStream => _stateCtl.stream;

  @override
  bool get supportsBytesOutput => supportsBytes;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    if (_refuses(text.trim())) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }
    return Uint8List.fromList(utf8.encode(text.trim()));
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    spokenFromBytes.add(utf8.decode(bytes));
    await speak(utf8.decode(bytes));
  }

  @override
  Future<void> speak(String text) async {
    if (disposed) throw StateError('speak() on a disposed service');
    final trimmed = text.trim();
    spoken.add(trimmed);

    if (_refuses(trimmed)) {
      throw TTSUnpronounceableFragmentException('fake fragment');
    }
    if (trimmed == failGenericOn) {
      throw TTSException('Edge TTS request failed: simulated outage');
    }

    _stateCtl.add(PlayerState.playing);
    if (emitStrayStopBeforeComplete) {
      Timer(Duration(milliseconds: audioMs ~/ 2), () {
        if (!disposed) _stateCtl.add(PlayerState.stopped);
      });
    }
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

  test('a sentence that normalizes away is skipped, never fetched', () async {
    // The second half of the same server rule.  The edge-tts provider puts the
    // text in a path segment, and Werkzeug's `path` converter needs at least
    // one character that is not a newline -- so `/tts/ja-JP/` (an empty
    // sentence) 404s exactly like the trailing-newline case does.  A 404 is a
    // real error to this client, so an unguarded ghost sentence kills the page.
    //
    // The web player advances past these instead of speaking them
    // (`tts-player.js`: `if (!cleanText) { ttsAdvance(); return; }`).
    final fake = FakeEdgeTTSService();
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final sentences = _page();
    // A ghost: whitespace, a zero-width space and a line break, nothing else.
    sentences[2] = const TTSPlayerSentence(sentenceId: 2, text: '\n \u200B ');
    // The sentence from the report, newline included.
    sentences[4] = const TTSPlayerSentence(
      sentenceId: 4,
      text: '作词 : 上江洌清作\n',
    );

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(sentences);
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(
      fake.spoken,
      isNot(contains('')),
      reason: 'an empty sentence would build /tts/<lang>/ and 404',
    );
    expect(
      fake.spoken,
      contains('作词 : 上江洌清作'),
      reason: 'the sentence itself is still read -- only normalized',
    );

    // Assert on the snippet text, not on what the fake recorded: `snippet.text`
    // is the string `_fetchAudio` puts in the URL path, and the fake trims what
    // it receives -- which would hide a surviving newline.
    final snippets = container.read(ttsPlayerProvider).snippets;
    expect(
      snippets[2].text,
      isEmpty,
      reason: 'the ghost sentence must normalize away',
    );
    expect(
      snippets[4].text,
      '作词 : 上江洌清作',
      reason: 'the trailing newline must be gone before the URL is built',
    );
    expect(
      container.read(ttsPlayerProvider).errorMessage,
      isNull,
      reason: 'neither case may surface as an error banner',
    );
  });

  test('连着一串念不出来的句子会停下报错，而不是无声地读完整页', () async {
    // 服务端对**任何**合成失败都答同一个 422：语言不对导致的「整页都念不
    // 出来」和一句孤立的 `」` 在响应上长得一模一样。以前两种都按「跳过」
    // 处理 —— 于是整页一句句往前跑、一点声音都没有，还不报错。连着一串就
    // 必须改判为服务端整体失败。
    final fake = FakeEdgeTTSService();
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final sentences = <TTSPlayerSentence>[
      const TTSPlayerSentence(sentenceId: 0, text: '」'),
      const TTSPlayerSentence(sentenceId: 1, text: '」'),
      const TTSPlayerSentence(sentenceId: 2, text: '」'),
      const TTSPlayerSentence(sentenceId: 3, text: 'ここは読まれてはいけません。'),
    ];

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(sentences);
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final state = container.read(ttsPlayerProvider);
    expect(
      state.status,
      TTSPlayerStatus.error,
      reason: '连续 3 句 422 是服务端整体念不出来，必须停下并说话',
    );
    expect(state.errorMessage, isNotNull);
    expect(
      fake.spoken.contains('ここは読まれてはいけません。'),
      isFalse,
      reason: '判定为整体失败后，不能继续往下无声地念',
    );
  });

  test('stopped 永远不算「这句读完了」', () async {
    // 一句读到一半的 stopped（我们自己 stop 的回声、或 on-device 引擎报错）
    // 曾经落在 750ms 窗口外被读成「读完」，高亮平白跳一句、跑到音频前面。
    final fake = FakeEdgeTTSService(
      audioMs: 400,
      emitStrayStopBeforeComplete: true,
    );
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(_page());
    await notifier.play();

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      container.read(ttsPlayerProvider).currentIndex,
      0,
      reason: 'stopped 不是「读完」，高亮必须还停在第一句',
    );

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      container.read(ttsPlayerProvider).currentIndex,
      greaterThan(0),
      reason: 'completed 触发的推进不能跟着一起被丢掉',
    );
  });

  test('本页的语言按书传下来，并换算成 Edge 标签', () async {
    final fake = FakeEdgeTTSService();
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    final notifier = container.read(ttsPlayerProvider.notifier);

    notifier.loadPage(_page(), bookLanguageName: 'Japanese');
    var state = container.read(ttsPlayerProvider);
    expect(state.languageTag, 'ja-JP');
    expect(state.languageResolved, isTrue);
    expect(state.notice, isNull);

    // 认不出来的语言名不能靠「看着像默认值」蒙过去：播放条必须把它说出来
    // —— 这正是「日文句子被发去英文语音」那一刻的样子。
    notifier.loadPage(_page(), bookLanguageName: 'English (US, legacy)');
    state = container.read(ttsPlayerProvider);
    expect(state.languageResolved, isFalse);
    expect(state.languageTag, 'en');
    expect(
      state.notice,
      isNotNull,
      reason: '回退语言码必须显示出来，否则线上只能靠服务端日志反推',
    );
  });

  test('单发的 422 先原句重试一次，读回来了就不算碎片', () async {
    // 服务端对**正常**句子也会偶发 422：实测同一页里
    // 「しかし、誰もいません。」被拒过一次，同一 URL 重试立刻 200。
    // 不重试就跳过，用户会白丢一句。
    final fake = FakeEdgeTTSService();
    final container = _containerFor(fake);
    addTearDown(() {
      container.dispose();
      fake.dispose();
    });

    const flaky = 'しかし、誰もいません。';
    fake.refuseFirstAttemptOnly.add(flaky);
    final sentences = <TTSPlayerSentence>[
      const TTSPlayerSentence(sentenceId: 0, text: flaky),
      const TTSPlayerSentence(sentenceId: 1, text: 'つぎの文です。'),
    ];

    final notifier = container.read(ttsPlayerProvider.notifier);
    notifier.loadPage(sentences);
    await notifier.play();
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      fake.spoken.where((s) => s == flaky).length,
      2,
      reason: '第一次被拒后必须原句重试一次',
    );
    expect(
      fake.spoken,
      contains('つぎの文です。'),
      reason: '重试成功就照常往下读',
    );
    expect(container.read(ttsPlayerProvider).errorMessage, isNull);
  });
}
