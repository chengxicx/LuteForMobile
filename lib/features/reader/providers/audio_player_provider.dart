import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../../core/network/content_service.dart';
import '../../../core/network/session_manager.dart';
import 'reader_provider.dart';
import '../utils/player_save_policy.dart';
import '../../../features/settings/providers/settings_provider.dart';

class AudioPlayerState {
  final AudioPlayer audioPlayer;
  final PlayerState playerState;
  final Duration position;
  final Duration duration;
  final List<Duration> bookmarkDurations;
  final String? errorMessage;
  final bool isLoading;
  final double playbackSpeed;
  final bool loopMode;
  final bool autoPauseMode;

  AudioPlayerState({
    required this.audioPlayer,
    required this.playerState,
    required this.position,
    required this.duration,
    required this.bookmarkDurations,
    this.errorMessage,
    required this.isLoading,
    this.playbackSpeed = 1.0,
    this.loopMode = false,
    this.autoPauseMode = false,
  });

  List<double> get bookmarkPositions {
    return bookmarkDurations
        .map((duration) => duration.inMilliseconds / 1000.0)
        .toList();
  }

  AudioPlayerState copyWith({
    AudioPlayer? audioPlayer,
    PlayerState? playerState,
    Duration? position,
    Duration? duration,
    List<Duration>? bookmarkDurations,
    String? errorMessage,
    bool? isLoading,
    double? playbackSpeed,
    bool? loopMode,
    bool? autoPauseMode,
  }) {
    return AudioPlayerState(
      audioPlayer: audioPlayer ?? this.audioPlayer,
      playerState: playerState ?? this.playerState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bookmarkDurations: bookmarkDurations ?? this.bookmarkDurations,
      errorMessage: errorMessage ?? this.errorMessage,
      isLoading: isLoading ?? this.isLoading,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      loopMode: loopMode ?? this.loopMode,
      autoPauseMode: autoPauseMode ?? this.autoPauseMode,
    );
  }
}

class AudioPlayerNotifier extends Notifier<AudioPlayerState> {
  AudioPlayer? _audioPlayer;
  Timer? _autoSaveTimer;
  int _bookId = 0;
  int _page = 0;

  /// 最近一次成功 loadAudio 的装配签名(与 AudioPlayerWidget 的
  /// loadSignature 同构)。播放条在 MP3⇄TTS 模式切换时会重新挂载,
  /// 此时音源还在这台播放器上,签名未变就不按旧的服务器进度重载,
  /// 保住用户切换前的播放位置。
  String? lastLoadSignature;

  /// 最近一次 loadAudio 的音源地址,供 play() 的重新装载兜底复用。
  String? _lastAudioUrl;

  /// 切后台前播放到的位置，等回到前台时用来复位播放条。
  ///
  /// 切后台会停播（`shouldStopAudioOnLifecycleChange` 只认 `paused`），而
  /// `_audioPlayer.stop()` 会推一个 `position = 0` 的事件 —— 那是
  /// audioplayers 的正常行为，不是数据丢了。位置在停播前已经存进服务端，
  /// 但「回前台」这条路径不会重新拉页面（`_checkServerPage()` 只在服务端
  /// 页码不同时才翻页），所以不会走 `loadAudio`，也就没机会 seek 回去，
  /// 播放条于是显示 00:00，看起来像进度没了。
  ///
  /// 2026-09-27 Leaf 5C 实测：切后台前 30.3%，回来 1.0%（= 0）。
  Duration? _positionBeforeSuspend;

  /// 下次 [play] 需要先重新装载并 seek，而不是直接 `resume()`。
  ///
  /// 由 [restoreAfterBackground] 置起：从后台回来时播放器已被 stop，内部
  /// 位置清零，直接 `resume()` 会从头播。见 [play] 里的说明。
  bool _needsSeekBeforePlay = false;

  /// 本会话是否**真的从页面加载到了**书签列表。
  ///
  /// 只有加载到了才允许把 `state.bookmarkPositions` 写回服务端。没加载到
  /// 时手上那份"空列表"只是"不知道"，不是"这本书没有书签" —— 把它当成
  /// 后者上报，就是全库书签被清空的原因（Leaf5C 实测：重开一次书，
  /// `BkAudioBookmarks` 从 `86.989` 变成 NULL）。
  bool _bookmarksAuthoritative = false;

  late ContentService _contentService;
  String? _previousServerUrl;

  /// audioplayers 6.x cannot send request headers for remote sources, so
  /// when the server requires auth (session cookie / Basic Auth) the audio
  /// is streamed into a cache file and played back from disk instead.
  static final Dio _audioDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
    ),
  );

  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _completeSubscription;

  @override
  AudioPlayerState build() {
    _cancelSubscriptions();

    ref.onDispose(() {
      _autoSaveTimer?.cancel();
      _cancelSubscriptions();
      _audioPlayer?.dispose();
      _audioPlayer = null;
    });

    _audioPlayer ??= AudioPlayer();
    _audioPlayer!.setReleaseMode(ReleaseMode.stop);
    _contentService = ref.read(readerRepositoryProvider).contentService;

    final settings = ref.read(settingsProvider);
    if (_previousServerUrl == null) {
      _previousServerUrl = settings.serverUrl;
    } else if (_previousServerUrl != settings.serverUrl) {
      _previousServerUrl = settings.serverUrl;
      _contentService = ref.read(readerRepositoryProvider).contentService;
    }

    _setupPlayerListeners();
    return AudioPlayerState(
      audioPlayer: _audioPlayer!,
      playerState: PlayerState.stopped,
      position: Duration.zero,
      duration: Duration.zero,
      bookmarkDurations: [],
      errorMessage: null,
      isLoading: false,
      playbackSpeed: 1.0,
    );
  }

  void _cancelSubscriptions() {
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completeSubscription?.cancel();
  }

  void _setupPlayerListeners() {
    _playerStateSubscription = _audioPlayer!.onPlayerStateChanged.listen((
      playerState,
    ) {
      state = state.copyWith(playerState: playerState);
      if (playerState == PlayerState.paused ||
          playerState == PlayerState.stopped ||
          playerState == PlayerState.completed) {
        unawaited(_savePosition());
      }
    });

    _positionSubscription = _audioPlayer!.onPositionChanged.listen((position) {
      _handlePositionChanged(position);
    });

    _durationSubscription = _audioPlayer!.onDurationChanged.listen((duration) {
      state = state.copyWith(duration: duration);
    });

    _completeSubscription = _audioPlayer!.onPlayerComplete.listen((_) {
      state = state.copyWith(
        playerState: PlayerState.stopped,
        position: Duration.zero,
      );
      unawaited(_savePosition());
    });
  }

  void _handlePositionChanged(Duration position) {
    final bookmarks = state.bookmarkDurations;

    // Sentence loop / auto-pause.
    //
    // Bookmarks are the sentence/segment start timestamps (the audio
    // bookmark data synced from the server).  The current segment spans
    // from the last bookmark at/before the playhead to the next bookmark
    // (or the audio end for the final segment).  When the playhead
    // crosses the segment end:
    //   - loop mode: seek back to the segment start and keep playing.
    //   - auto-pause mode: seek back to the segment start and pause, so
    //     pressing play replays the same sentence.
    // Loop takes precedence over auto-pause, matching the web player.
    var finalPosition = position;
    if (bookmarks.isNotEmpty &&
        state.playerState == PlayerState.playing) {
      int segStartIndex = -1;
      for (var i = bookmarks.length - 1; i >= 0; i--) {
        if (bookmarks[i] <= position) {
          segStartIndex = i;
          break;
        }
      }

      if (segStartIndex >= 0) {
        final segStart = bookmarks[segStartIndex];
        final segEnd = segStartIndex + 1 < bookmarks.length
            ? bookmarks[segStartIndex + 1]
            : state.duration;

        if (segEnd > segStart && position >= segEnd) {
          if (state.loopMode) {
            unawaited(_audioPlayer?.seek(segStart));
            finalPosition = segStart;
          } else if (state.autoPauseMode) {
            unawaited(_audioPlayer?.seek(segStart));
            unawaited(_audioPlayer?.pause());
            finalPosition = segStart;
          }
        }
      }
    }

    state = state.copyWith(position: finalPosition);
  }

  Future<void> toggleLoopMode() async {
    final newLoop = !state.loopMode;
    state = state.copyWith(loopMode: newLoop);

    // Mirrors the web player: turning the loop on while the audio is
    // paused (e.g. auto-paused at the end of a sentence) resumes
    // playback so the sentence starts looping immediately.
    if (newLoop &&
        state.playerState != PlayerState.playing &&
        state.duration > Duration.zero) {
      try {
        await _audioPlayer?.resume();
      } catch (_) {
        // Ignore resume failures (e.g. no source loaded yet).
      }
    }
  }

  void toggleAutoPauseMode() {
    state = state.copyWith(autoPauseMode: !state.autoPauseMode);
  }

  Future<void> loadAudio({
    required String audioUrl,
    required int bookId,
    required int page,
    List<double>? bookmarks,
    Duration? audioCurrentPos,
  }) async {
    _reset();
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      _bookId = bookId;
      _page = page;
      _lastAudioUrl = audioUrl;

      // Convert bookmarks to Duration objects
      final bookmarkDurations =
          bookmarks?.map((pos) {
            return Duration(milliseconds: (pos * 1000).round());
          }).toList() ??
          [];

      state = state.copyWith(bookmarkDurations: bookmarkDurations);
      // `bookmarks == null` 是"页面没告诉我们"，不是"没有书签"；只有前者
      // 之外的情况才允许写回，见 `_bookmarksAuthoritative`。
      _bookmarksAuthoritative = bookmarks != null;

      await _audioPlayer!.stop();
      final authHeaders = SessionManager.authHeaders();
      if (authHeaders.isEmpty) {
        await _audioPlayer!.setSourceUrl(audioUrl);
      } else {
        final audioFile = await _ensureLocalAudioFile(audioUrl, authHeaders);
        await _audioPlayer!.setSourceDeviceFile(audioFile.path);
      }

      if (audioCurrentPos != null && audioCurrentPos > Duration.zero) {
        // 先把目标位置落进 state，再 seek。
        //
        // `state.position` **只**由 `onPositionChanged` 更新（见
        // `_handlePositionChanged`），而 seek 之后播放器不保证会推一个位置事件
        // —— 暂停态、以及刚 `setSource` 完还没准备好的时候都可能一个事件都不发。
        // 这时 `state.position` 会一直停在 `_reset()` 留下的 0，而 2 秒后的
        // 自动保存就把这个 0 写回服务端：**打开一本书就把库里的位置清成 0**。
        // 实测（2026-09-27 Leaf 5C）：种入 `149.277379`，重开一次后库里变成
        // `0.0`，界面回到 00:00。与"书签被清空"是同一类破坏。
        //
        // 乐观写入不会掩盖真实进度：一旦播放器真的开始推位置事件，
        // `_handlePositionChanged` 会立刻用真实值覆盖它。
        state = state.copyWith(position: audioCurrentPos);
        await _audioPlayer!.seek(audioCurrentPos);
      }

      state = state.copyWith(isLoading: false);

      final settings = ref.read(settingsProvider);
      if (settings.showAudioPlayer) {
        _startAutoSave();
      }
      final bookmarkSignature = (bookmarks ?? const <double>[])
          .map((pos) => pos.toStringAsFixed(3))
          .join(',');
      lastLoadSignature =
          '$audioUrl|$bookId|$page|'
          '${audioCurrentPos?.inMilliseconds.toString() ?? 'null'}|'
          '$bookmarkSignature';
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> play() async {
    try {
      // 从后台回来时播放器是 stopped 的（`_stopSafely()` 停的），而
      // `stop()` 已经把它内部的位置清零了。此时 `resume()` 会**从头播**，
      // 但状态确实变成 playing，于是 `_waitUntilPlaying()` 返回 true，
      // 下面那段重装兜底不会触发 —— 播放条明明停在 01:41，一按播放却从 0
      // 开始（2026-09-27 Leaf 5C 实测：按播放后 32.1% → 4.1%）。
      //
      // 所以这种情况直接走「重新装载 + seek 回原位置」的路径，
      // `_reloadSourceAndPlay()` 会用 `state.position`（已由
      // `restoreAfterBackground()` 复位）seek 回去。
      if (_needsSeekBeforePlay) {
        _needsSeekBeforePlay = false;
        await _reloadSourceAndPlay();
        return;
      }
      await _audioPlayer!.resume();
      // audioplayers 的 resume() 在部分设备上对"已准备好但从未起播"的
      // 播放器(刚 setSource 完、位置为 0)会静默无效:焦点正常申请,
      // MediaPlayer 却不真正 start。短暂等待确认没起播,就重新装载
      // 音源再起播兜底。
      if (!await _waitUntilPlaying()) {
        await _reloadSourceAndPlay();
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<bool> _waitUntilPlaying() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (state.playerState == PlayerState.playing) return true;
    }
    return false;
  }

  /// 重新走一遍装载序列(与 loadAudio 相同的 stop → setSource → seek),
  /// seek 之后再显式 resume。这是在真机上验证过能起播的路径。
  Future<void> _reloadSourceAndPlay() async {
    final url = _lastAudioUrl;
    if (url == null || _audioPlayer == null) return;

    // 目标位置必须在动音源**之前**取。
    //
    // `stop()` 和 `setSource*()` 都会把播放器的位置清零，并各推一个
    // `position = 0` 的事件回来（`_handlePositionChanged` 会把它写进
    // `state`）。原来是在装载完再读 `state.position` 的，那时它已经是 0，
    // 于是 seek 退化成 seek(1ms) —— "从原位置重装起播"变成了"从头播"。
    // 2026-09-27 Leaf 5C 实测：切后台回来播放条停在 30.9%，按播放却从 0 开始。
    //
    // 这条路径原本只服务于"resume 无效"的兜底，那种情况下位置本来就是 0，
    // 所以缺陷一直没暴露；现在它还要负责从后台回来后的续播，就露出来了。
    final target = state.position > Duration.zero
        ? state.position
        : const Duration(milliseconds: 1);

    debugPrint('AudioPlayer: resume 无效,重新装载音源再起播 target=$target');
    try {
      await _audioPlayer!.stop();
      final authHeaders = SessionManager.authHeaders();
      if (authHeaders.isEmpty) {
        await _audioPlayer!.setSourceUrl(url);
      } else {
        final audioFile = await _ensureLocalAudioFile(url, authHeaders);
        await _audioPlayer!.setSourceDeviceFile(audioFile.path);
      }
      // 位置为 0 时也 seek 一次,借道 seek() 的 stopped→resume 补救路径。
      await _audioPlayer!.seek(target);
      if (state.playerState != PlayerState.playing) {
        await _audioPlayer!.resume();
      }
      if (state.playbackSpeed != 1.0) {
        await _audioPlayer!.setPlaybackRate(state.playbackSpeed);
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> pause() async {
    await _audioPlayer!.pause();
    await _savePosition();
  }

  Future<void> seek(Duration position) async {
    await _audioPlayer!.seek(position);
    // 同上：暂停态的 seek 不保证推位置事件，而下面立刻就要 `_savePosition()`。
    // 不显式写 state 的话，拖到开头会保存旧位置、拖到别处会保存 0。
    state = state.copyWith(position: position);
    if (state.playerState == PlayerState.stopped) {
      await Future.delayed(Duration(milliseconds: 50));
      await _audioPlayer!.resume();
    }
    await _savePosition();
  }

  Future<void> setPlaybackSpeed(double speed) async {
    await _audioPlayer!.setPlaybackRate(speed);
    state = state.copyWith(playbackSpeed: speed);
  }

  void addBookmark() {
    final currentPosition = state.position;
    final bookmarks = List<Duration>.from(state.bookmarkDurations);

    final hasNearbyBookmark = bookmarks.any(
      (bookmark) => (bookmark - currentPosition).abs() < Duration(seconds: 1),
    );

    if (!hasNearbyBookmark) {
      bookmarks.add(currentPosition);
      bookmarks.sort((a, b) => a.compareTo(b));
      state = state.copyWith(bookmarkDurations: bookmarks);
      _savePosition(includeBookmarks: true);
    }
  }

  void removeBookmark() {
    final currentPosition = state.position;
    final bookmarks = List<Duration>.from(state.bookmarkDurations);

    bookmarks.removeWhere(
      (b) => (b - currentPosition).abs() < Duration(seconds: 1),
    );
    state = state.copyWith(bookmarkDurations: bookmarks);
    _savePosition(includeBookmarks: true);
  }

  void goToPreviousBookmark() {
    final currentPosition = state.position;
    final bookmarks = state.bookmarkDurations;

    if (bookmarks.isEmpty) return;

    final previousBookmarks = bookmarks
        .where((b) => currentPosition - b > Duration(milliseconds: 800))
        .toList();

    if (previousBookmarks.isNotEmpty) {
      final nearestBookmark = previousBookmarks.reduce((a, b) => a > b ? a : b);
      seek(nearestBookmark);
    }
  }

  void goToNextBookmark() {
    final currentPosition = state.position;
    final bookmarks = state.bookmarkDurations;

    if (bookmarks.isEmpty) return;

    final nextBookmarks = bookmarks.where((b) => b > currentPosition).toList();

    if (nextBookmarks.isNotEmpty) {
      final nearestBookmark = nextBookmarks.reduce((a, b) => a < b ? a : b);
      seek(nearestBookmark);
    }
  }

  bool isAtBookmark() {
    final currentPosition = state.position;
    return state.bookmarkDurations.any(
      (b) => (b - currentPosition).abs() < Duration(seconds: 1),
    );
  }

  void _startAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      unawaited(_savePosition());
    });
  }

  void _reset() {
    if (_bookId != 0) {
      unawaited(_savePosition());
    }
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _bookId = 0;
    _page = 0;
    _positionBeforeSuspend = null;
    _needsSeekBeforePlay = false;
    _bookmarksAuthoritative = false;
    lastLoadSignature = null;
    _lastAudioUrl = null;
    _stopSafely();
  }

  void reset() {
    _reset();
  }

  /// 切后台：存位置、停播，但**保留音源地址与进度**。
  ///
  /// 与 [reset] 的区别在收尾：`reset()` 把 `_lastAudioUrl` / `lastLoadSignature`
  /// 一并清掉，那是「卸载音源」的语义（换书、关阅读页、模式切换用它）。
  /// 切后台不是卸载 —— 用户只是切走了，回来还在同一本书、同一页、同一个
  /// 位置，所以这里只停播。
  ///
  /// 保留 `_lastAudioUrl` 是必须的：回到前台按播放时，`play()` 会发现
  /// `resume()` 对已 stop 的播放器无效，转走 `_reloadSourceAndPlay()`，
  /// 而那条路径要靠 `_lastAudioUrl` 重新装载、靠 `state.position` 重新
  /// seek。两者任何一个被清掉，按播放就再也起不来。
  ///
  /// 刻意**不自动起播**：后台停播是设计（见 `utils/player_lifecycle.dart`），
  /// 这里只负责让播放条别假装什么都没播过。
  void suspendForBackground() {
    if (_bookId == 0) return;
    _positionBeforeSuspend = state.position;
    unawaited(_savePosition());
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _stopSafely();
  }

  /// 回到前台：把播放条复位到切走前的位置。
  ///
  /// 在 `resumed` 时调用，而不是在 `suspendForBackground()` 里立刻写回 ——
  /// `stop()` 推来的 `position = 0` 事件是异步的，紧接着写回会被它盖掉。
  /// 到 `resumed` 时那次事件早已到达（间隔是秒级，事件是毫秒级），写回稳定。
  ///
  /// 同时置起 [_needsSeekBeforePlay]：只把播放条画回原处是不够的，播放器
  /// 内部的位置已经被 `stop()` 清零，按播放还得先 seek 回去，否则会从头播。
  void restoreAfterBackground() {
    final position = _positionBeforeSuspend;
    _positionBeforeSuspend = null;
    if (position == null || position <= Duration.zero) return;
    state = state.copyWith(position: position);
    _needsSeekBeforePlay = true;
  }

  /// Returns a local copy of [audioUrl], downloading it (streaming to disk)
  /// with the session auth headers when the cached copy does not match the
  /// remote size.
  Future<File> _ensureLocalAudioFile(
    String audioUrl,
    Map<String, String> authHeaders,
  ) async {
    final cacheDir = await getApplicationCacheDirectory();
    final audioDir = Directory('${cacheDir.path}/audiobooks');
    await audioDir.create(recursive: true);
    final cacheFile = File(
      '${audioDir.path}/audiobook_${_bookId}_${audioUrl.hashCode.abs()}.audio',
    );

    final remoteSize = await _probeAudioSize(audioUrl, authHeaders);
    if (remoteSize != null) {
      final localSize = await cacheFile.exists()
          ? await cacheFile.length()
          : -1;
      if (localSize == remoteSize) {
        return cacheFile;
      }
    }

    await _downloadAudioToFile(audioUrl, authHeaders, cacheFile);
    return cacheFile;
  }

  Future<int?> _probeAudioSize(
    String url,
    Map<String, String> authHeaders,
  ) async {
    try {
      final response = await _audioDio.get<ResponseBody>(
        url,
        options: Options(
          headers: {...authHeaders, 'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 206) {
        final contentRange = response.headers.value('content-range') ?? '';
        final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
        return match != null ? int.tryParse(match.group(1)!) : null;
      }
      if (status == 200) {
        final contentLength = response.headers.value('content-length');
        return contentLength != null ? int.tryParse(contentLength) : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _downloadAudioToFile(
    String url,
    Map<String, String> authHeaders,
    File target, {
    bool retriedAfterLogin = false,
  }) async {
    final tmp = File('${target.path}.part');
    IOSink? sink;
    try {
      final response = await _audioDio.get<ResponseBody>(
        url,
        options: Options(
          headers: authHeaders,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        // Redirected (e.g. to /login): the multi-user session is gone.
        if (!retriedAfterLogin && await SessionManager.tryAutoRelogin()) {
          await _downloadAudioToFile(
            url,
            SessionManager.authHeaders(),
            target,
            retriedAfterLogin: true,
          );
          return;
        }
        throw const ServerLoginRequiredException();
      }
      sink = tmp.openWrite();
      await sink.addStream(response.data!.stream);
      await sink.flush();
      await sink.close();
      sink = null;
      await tmp.rename(target.path);
    } catch (_) {
      try {
        sink ??= tmp.openWrite();
        await sink.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  Future<void> stop() async {
    _stopSafely();
  }

  void _stopSafely() {
    try {
      _audioPlayer?.stop();
    } catch (_) {
      // Player may be disposed
    }
  }

  /// 把进度写回服务端。
  ///
  /// [includeBookmarks] 只在**用户真的改了书签**（[addBookmark] /
  /// [removeBookmark]）时为 true。这个开关不是优化，是防数据丢失：
  ///
  /// 阅读页整页有 14 天 TTL 的 Hive 缓存（`PageCacheService`），
  /// `LUTE_YT_DATA.bookmarks` 是页面的一部分，所以 app 手里的书签列表可能
  /// 是十几天前的快照。若 2 秒一次的自动保存也把书签带上，用户昨天在 web 端
  /// 新加的书签就会被这份旧快照**覆盖掉** —— 和之前"每次开书把书签清空"
  /// 是同一类破坏，只是方向相反。进度是持续变化的遥测，必须定时写；
  /// 书签是用户编辑的数据，只在被编辑的那一刻写。
  Future<void> _savePosition({bool includeBookmarks = false}) async {
    if (_bookId == 0) return;
    try {
      final positionSeconds = state.position.inMilliseconds / 1000.0;
      final durationSeconds = state.duration.inMilliseconds / 1000.0;

      // 没加载到书签、或这次不是用户改书签触发的，就**不带** bookmarks
      // 字段，而不是带一个空列表。规则见 bookmarksToPost。
      final bookmarkPositions = bookmarksToPost(
        userEdited: includeBookmarks,
        authoritative: _bookmarksAuthoritative,
        bookmarks: state.bookmarkPositions,
      );

      await _contentService.saveAudioPlayerData(
        bookId: _bookId,
        page: _page,
        position: positionSeconds,
        duration: durationSeconds,
        bookmarks: bookmarkPositions,
      );
    } catch (e) {
      // Error handling is done in the service layer
      print('Error saving audio player data: $e');
    }
  }
}

final audioPlayerProvider =
    NotifierProvider<AudioPlayerNotifier, AudioPlayerState>(
      () => AudioPlayerNotifier(),
    );
