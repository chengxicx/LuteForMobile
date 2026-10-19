// 「后台播放」前台服务的 Dart 端契约测试。
//
// 背景（2026-10-19）：用户反馈锁屏就没声音。除了 Flutter 层主动停播，Android
// 还需要一个 mediaPlayback 前台服务把进程挂住。服务是全局一份，而 MP3 与整页
// 朗读 TTS 是两条独立链路，所以 Dart 侧用「持有者集合」而不是计数器：
//   * 同一个持有者反复 acquire/release 必须幂等（play() 每次起播都会调）；
//   * 只有最后一个持有者释放时才真的 stop，否则 TTS 停下会把还在播的 MP3
//     的前台资格一起撤掉。
//
// 运行：flutter test test/playback_foreground_service_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/services/playback_foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.schlick7.luteformobile/media_playback');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    PlaybackForegroundService.resetForTest();
    // 测试跑在 macOS 上，而通道只对 Android 生效：强制成 android 才走得到
    // 通道（不设的话 _supported 直接短路返回）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PlaybackForegroundService.resetForTest();
  });

  test('第一个持有者启动前台服务', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    expect(calls, ['start']);
  });

  test('第二个持有者不重复启动', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.acquire(PlaybackForegroundService.tts);
    expect(calls, ['start'], reason: '服务全局一份，第二个持有者不该再发 start');
  });

  test('同一持有者重复 acquire 是幂等的', () async {
    for (var i = 0; i < 5; i++) {
      await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    }
    expect(calls, ['start']);
    expect(PlaybackForegroundService.holdersForTest, {
      PlaybackForegroundService.mp3,
    });
  });

  test('仍有持有者时释放不停服务', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.acquire(PlaybackForegroundService.tts);
    await PlaybackForegroundService.release(PlaybackForegroundService.mp3);
    expect(
      calls,
      ['start'],
      reason: 'TTS 还在播，MP3 停下不该把前台资格撤掉',
    );
  });

  test('最后一个持有者释放才停服务', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.acquire(PlaybackForegroundService.tts);
    await PlaybackForegroundService.release(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.release(PlaybackForegroundService.tts);
    expect(calls, ['start', 'stop']);
  });

  test('重复 release 不会多发 stop', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.release(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.release(PlaybackForegroundService.mp3);
    expect(calls, ['start', 'stop']);
  });

  test('releaseAll 一把清空并停服务', () async {
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.acquire(PlaybackForegroundService.tts);
    await PlaybackForegroundService.releaseAll();
    expect(calls, ['start', 'stop']);
    expect(PlaybackForegroundService.holdersForTest, isEmpty);
  });

  test('非 Android 平台不发任何通道调用', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await PlaybackForegroundService.acquire(PlaybackForegroundService.mp3);
    await PlaybackForegroundService.release(PlaybackForegroundService.mp3);
    expect(calls, isEmpty);
  });
}
