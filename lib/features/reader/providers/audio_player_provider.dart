import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../../core/network/content_service.dart';
import '../../../core/network/session_manager.dart';
import '../../../shared/providers/server_status_provider.dart';
import 'reader_provider.dart';
import '../utils/audio_download_resume.dart';
import '../utils/pending_seek.dart';
import '../utils/player_save_policy.dart';
import '../../../features/settings/providers/settings_provider.dart';

/// AB 复读的三态：熄灭 → 已标 A → A↔B 循环中。会话级，不持久化。
enum AbLoopPhase { off, aMarked, looping }

class AudioPlayerState {
  final AudioPlayer audioPlayer;
  final PlayerState playerState;
  final Duration position;
  final Duration duration;

  /// 用户书签（服务端同步的手动时间戳）。时间轴刻度只画这一份。
  final List<Duration> bookmarkDurations;

  /// 句子分段边界（SRT cue 起点；无 cues 的老书签书回退为服务端书签）。
  /// 驱动循环/自动暂停的逐句判定与实体键/左右键的切句 —— 刻意**不画**上
  /// 时间轴：它是播放控制数据，不是书签。
  final List<Duration> segmentBoundaries;
  final String? errorMessage;
  final bool isLoading;
  final double playbackSpeed;
  final bool loopMode;
  final bool autoPauseMode;

  /// AB 复读的当前状态与 A/B 两点（off 态下两者为 null）。
  final AbLoopPhase abPhase;
  final Duration? abStart;
  final Duration? abEnd;

  /// copyWith 的「未传参」哨兵：`errorMessage ?? this.errorMessage` 会让
  /// 「传 null 表示清空」和「没传」变成同一件事，错误提示一旦写上就清不掉。
  static const Object _unset = Object();

  AudioPlayerState({
    required this.audioPlayer,
    required this.playerState,
    required this.position,
    required this.duration,
    required this.bookmarkDurations,
    this.segmentBoundaries = const [],
    this.errorMessage,
    required this.isLoading,
    this.playbackSpeed = 1.0,
    this.loopMode = false,
    this.autoPauseMode = false,
    this.abPhase = AbLoopPhase.off,
    this.abStart,
    this.abEnd,
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
    List<Duration>? segmentBoundaries,
    Object? errorMessage = _unset,
    bool? isLoading,
    double? playbackSpeed,
    bool? loopMode,
    bool? autoPauseMode,
    AbLoopPhase? abPhase,
    Object? abStart = _unset,
    Object? abEnd = _unset,
  }) {
    return AudioPlayerState(
      audioPlayer: audioPlayer ?? this.audioPlayer,
      playerState: playerState ?? this.playerState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bookmarkDurations: bookmarkDurations ?? this.bookmarkDurations,
      segmentBoundaries: segmentBoundaries ?? this.segmentBoundaries,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
      isLoading: isLoading ?? this.isLoading,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      loopMode: loopMode ?? this.loopMode,
      autoPauseMode: autoPauseMode ?? this.autoPauseMode,
      abPhase: abPhase ?? this.abPhase,
      // A/B 两点要支持「传 null 表示清除」，与 errorMessage 同一套哨兵。
      abStart: abStart == _unset ? this.abStart : abStart as Duration?,
      abEnd: abEnd == _unset ? this.abEnd : abEnd as Duration?,
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

  /// 最近一次 loadAudio 对应的本地缓存音频文件。起播不再等它 —— 缓存完整时
  /// 直接播它（离线可播、秒开），否则带鉴权头流式起播、后台再补进缓存；补完
  /// 之前为 null。影子跟读的原句裁剪播放从它取片段，免去另一套下载逻辑 ——
  /// 有声书的缓存本来就是离线播放的根基，复用同一份文件。
  File? lastLocalAudioFile;

  /// 已在下载/已下载过的 `${bookId}|$url`，避免同一次会话反复预取同一份音频
  /// （并发写同一个 `.part` 文件会互相破坏）。
  final Set<String> _prefetchingAudio = {};

  /// 正在跑的那条预取（同一时刻只留一条）与它的去重键。换书/换页时要把上
  /// 一条掐掉：旧书的 64MB 还在后台下，新书的又要开始，两条一起抢带宽。
  CancelToken? _prefetchCancel;
  String? _prefetchKey;

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

  /// 已发出、播放器还没报出结果的 seek：目标位置 + 出发位置 + 发出时刻。
  /// 见 [_seekStillPending] —— 跨段判定要等它真正落地，而不是等一个固定时长。
  Duration? _pendingSeekTarget;
  Duration? _pendingSeekOrigin;
  DateTime? _pendingSeekAt;

  /// 正在下发给播放器的那条 seek（见 [_seekPlayer]）。同一时刻只允许一条，
  /// 新的排在它后面 —— 两条同时在飞时先发的可能后生效，把后发的吞掉。
  Future<void>? _seekChain;

  /// 排队时最多等上一条 seek 多久。
  static const Duration _seekChainWait = Duration(seconds: 3);

  /// 最近一次句尾（循环/自动暂停）处理时刻。seek 回段首时在途的旧位置
  /// 事件还会到达，600ms 内不做第二次跨越判定，避免同一边界连环触发。
  DateTime? _boundaryHandledAt;

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
    // 暂停/停止态不收位置事件：播放器没在走，此刻到达的事件全是 seek 之前
    // 发出的迟到回声 —— 自动暂停 seek 回句首后它们会把显示和高亮推回句尾/
    // 下一句，切到下一句的 seek 也会被盖回去。显示由 seek() 的显式写入负责。
    if (state.playerState != PlayerState.playing) {
      return;
    }

    // 刚发出的 seek 还没落地之前，位置事件全是旧位置的迟到回声：既不能拿
    // 它们做跨段判定，也不能拿它们写 state.position —— 显示会被推回旧句，
    // 而"上一次位置"一旦被推回旧句，下一个事件看起来就跨过了边界，循环模式
    // 据此把播放头拽回旧句（用户看到的就是"按一下下一句没切过去"）。
    // 远程音源的 seekTo 要重新拉一段 Range 才生效，耗时秒级且不确定，
    // 所以这里等的是"位置真的到达目标"，不是"过了 N 毫秒"。
    if (_seekStillPending(position)) {
      return;
    }

    // A-B 复读优先于句段循环/自动暂停：用户圈了 A↔B 就听这一段，
    // 播放头到 B 回 A，句段边界在 AB 范围内不参与。
    if (state.abPhase == AbLoopPhase.looping &&
        state.abEnd != null &&
        position >= state.abEnd!) {
      final target = state.abStart ?? Duration.zero;
      debugPrint('AudioPlayer: AB loop reached B($position), back to A($target)');
      _markSeekIssued(target);
      unawaited(_seekPlayer(target));
      state = state.copyWith(position: target);
      return;
    }

    final boundaries = state.segmentBoundaries;

    // Sentence loop / auto-pause.
    //
    // Bookmarks are the sentence/segment start timestamps (the audio
    // bookmark data synced from the server, or the SRT cue starts derived
    // in reader_screen._loadAudioIfNeeded).  The segment being played ends
    // at the NEXT bookmark -- a sentence is finished when the playhead
    // CROSSES that bookmark, i.e. the previous position event was still
    // before it and this one is at/past it:
    //   - loop mode: seek back to the segment start and keep playing.
    //   - auto-pause mode: seek back to the segment start and pause, so
    //     pressing play replays the same sentence.
    // Loop takes precedence over auto-pause, matching the web player.
    //
    // 必须用「上一个位置事件」判定跨越，而不是拿当前位置反查所属段：位置
    // 事件一越过书签，"last bookmark <= position" 的归属就滑进新段了，
    // `position >= segEnd` 永远不成立 —— 旧写法就是这样让 MP3 的循环/
    // 自动暂停在全曲除最后一段外永远不触发的（2026-09-28 Leaf5C 实测，
    // JIGSAW 全程播完不停）。
    //
    // state.position 就是上一个事件的位置（seek() 会显式写入，所以用户
    // 拖进度条的大跳不会被判成"跨越"）；触发后 600ms 内不再判，吞掉
    // seek 回段首时在途的旧位置事件。
    var finalPosition = position;
    final handledRecently = _boundaryHandledAt != null &&
        DateTime.now().difference(_boundaryHandledAt!) <
            const Duration(milliseconds: 600);

    if (state.playerState == PlayerState.playing &&
        boundaries.isNotEmpty &&
        !handledRecently &&
        position > state.position) {
      Duration? crossed;
      for (final b in boundaries) {
        if (b > state.position && b <= position) {
          crossed = b;
          break;
        }
      }

      if (crossed != null) {
        // 刚播完这句的起点：crossed 之前最近的边界；第一个边界之前没有
        // 更早的划分，句首就是音频开头。
        var segStart = Duration.zero;
        for (final b in boundaries) {
          if (b < crossed) {
            segStart = b;
          } else {
            break;
          }
        }
        debugPrint(
          'AudioPlayer: segment boundary crossed at $position, '
          'boundary=$crossed, segStart=$segStart, '
          'loop=${state.loopMode}, autoPause=${state.autoPauseMode}',
        );
        _boundaryHandledAt = DateTime.now();
        _markSeekIssued(segStart);
        if (state.loopMode) {
          unawaited(_seekPlayer(segStart));
          finalPosition = segStart;
        } else if (state.autoPauseMode) {
          unawaited(_seekPlayer(segStart));
          unawaited(_audioPlayer?.pause());
          finalPosition = segStart;
        }
      }
    }

    state = state.copyWith(position: finalPosition);
  }

  /// 记下"刚发出一个 seek，目标是 [target]"，在播放器真的报出目标位置之前
  /// 位置事件不参与判定（见 [_seekStillPending]）。出发位置取当前 state，
  /// 调用方必须**先**调它、**再**把 state.position 改成目标。
  void _markSeekIssued(Duration target) {
    _pendingSeekTarget = target;
    _pendingSeekOrigin = state.position;
    _pendingSeekAt = DateTime.now();
  }

  void _clearPendingSeek() {
    _pendingSeekTarget = null;
    _pendingSeekOrigin = null;
    _pendingSeekAt = null;
  }

  /// 这次 seek 是不是还没落地。
  ///
  /// 原来这里是"发出后 600ms 内不判定"，在本地文件上够用，在**远程音源**上
  /// 不够：seekTo 要重新拉一段 Range 才生效，秒级且不确定，窗口一过，在途的
  /// 旧位置事件就会被当成真实前进 —— 循环/自动暂停据此把播放头拽回旧句，
  /// 用户按"下一句"看着就像没跳过去（切句、循环、自动暂停共用这条路径）。
  ///
  /// 所以改成"等到播放器报出的位置真的到达目标"（判定本身在
  /// `utils/pending_seek.dart` 里，纯函数、有单测）：
  ///  * 到达（含容差）→ 清除，并顺手补一次 600ms 回声屏蔽（落地后仍可能有
  ///    旧位置的迟到事件）；
  ///  * 播放器始终没报（seek 失败 / 音源被换掉）→ 超时后放弃等待，
  ///    别把播放条永久冻在目标位置上。
  bool _seekStillPending(Duration position) {
    final target = _pendingSeekTarget;
    final origin = _pendingSeekOrigin;
    if (target == null || origin == null) return false;
    final verdict = evaluatePendingSeek(
      position: position,
      target: target,
      origin: origin,
      elapsed: DateTime.now().difference(_pendingSeekAt!),
    );
    switch (verdict) {
      case PendingSeekVerdict.pending:
        return true;
      case PendingSeekVerdict.expired:
        debugPrint('AudioPlayer: seek 到 $target 迟迟没落地，放弃等待');
        _clearPendingSeek();
        return false;
      case PendingSeekVerdict.proceed:
        _clearPendingSeek();
        _boundaryHandledAt = DateTime.now();
        return false;
    }
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
    List<double>? segmentBoundaries,
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
      final segmentDurations =
          segmentBoundaries?.map((pos) {
            return Duration(milliseconds: (pos * 1000).round());
          }).toList() ??
          [];

      state = state.copyWith(
        bookmarkDurations: bookmarkDurations,
        segmentBoundaries: segmentDurations,
        // 换书/换页把上一次的 AB 复读一并清掉。
        abPhase: AbLoopPhase.off,
        abStart: null,
        abEnd: null,
      );
      // `bookmarks == null` 是"页面没告诉我们"，不是"没有书签"；只有前者
      // 之外的情况才允许写回，见 `_bookmarksAuthoritative`。分段边界
      // （SRT 派生）不参与书签写回 —— 它们在 `segmentBoundaries` 里，
      // 与书签彻底分家。
      _bookmarksAuthoritative = bookmarks != null;

      await _audioPlayer!.stop();
      await _setAudioSource(audioUrl, SessionManager.authHeaders());

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
      final segmentSignature = (segmentBoundaries ?? const <double>[])
          .map((pos) => pos.toStringAsFixed(3))
          .join(',');
      lastLoadSignature =
          '$audioUrl|$bookId|$page|'
          '${audioCurrentPos?.inMilliseconds.toString() ?? 'null'}|'
          '$bookmarkSignature|$segmentSignature';
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
      await _setAudioSource(url, SessionManager.authHeaders());
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

  /// 跳到 [position]。
  ///
  /// [autoplay] 为 true 时，播放器当前哪怕是 paused 也要起播 —— 逐句精听
  /// （自动暂停开着）里按"上一句/下一句"必须让目标句立刻开口，这是网页播放
  /// 器的行为（media-player-base.js 的 `ytSeekToCue(target, autoplay)`，
  /// youtube-player.js 传 `jumpCueAutoplay: "autopause"`）。app 侧原来只认
  /// `stopped`，而自动暂停停在句首时播放器是 `paused`，于是按了只挪播放头、
  /// 不出声 —— 用户看到的就是"前后不能跳句子"（2026-10-10 手机实测复现）。
  Future<void> seek(Duration position, {bool autoplay = false}) async {
    // 目标位置先落进 state，再动播放器：远程音源的 seekTo 要重新拉一段
    // Range 才生效，期间位置事件还是旧值，不先写就是"按了没反应"。
    // 顺序要紧 —— _markSeekIssued 拿当前 state.position 当"出发位置"，
    // 必须排在写 state 之前。
    _markSeekIssued(position);
    state = state.copyWith(position: position);
    await _seekPlayer(position);
    // 暂停态的 seek 不保证推位置事件，而下面立刻就要 `_savePosition()`。
    // 不显式写 state 的话，拖到开头会保存旧位置、拖到别处会保存 0。
    // （上面已写一次，这里补一次是给 await 期间到达的迟到事件兜底。）
    state = state.copyWith(position: position);
    if (state.playerState == PlayerState.stopped) {
      await Future.delayed(const Duration(milliseconds: 50));
      await _audioPlayer!.resume();
    } else if (autoplay && state.playerState != PlayerState.playing) {
      await _audioPlayer!.resume();
    }
    await _savePosition();
  }

  /// 把一次 seek 指令下发到播放器，**串在 [_seekChain] 后面**。
  ///
  /// 为什么要排队：远程音源上两个 seek 同时在飞时，先发的那个可能**后**生效，
  /// 把后发的吞掉。2026-10-10 手机实测：循环模式播到句尾、自动回句首的那次
  /// seek 还在飞时按"下一句"，播放头最后停在句首 —— 用户按了等于没按
  /// （[seek] 已经把目标写进 state，[PendingSeekVerdict] 也会等到它落地，
  /// 但播放器根本没往那儿走）。
  ///
  /// 等待有上限（[_seekChainWait]）：播放器偶尔不回报 seek 完成，不能因此
  /// 把后面所有的跳句永久堵死。
  Future<void> _seekPlayer(Duration target) async {
    final previous = _seekChain;
    final gate = Completer<void>();
    _seekChain = gate.future;
    if (previous != null) {
      await previous.timeout(_seekChainWait, onTimeout: () {});
    }
    try {
      await _audioPlayer!.seek(target);
    } catch (e) {
      // 单个 seek 失败不该冒泡成未捕获异常（调用方多是 unawaited）。
      debugPrint('AudioPlayer: seek $target 失败: $e');
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
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

  /// AB 复读三态：熄灭 → 标 A → 标 B 并立即回 A 开始循环 → 熄灭。
  /// B 没标到 A 之后（误触/seek 到 A 之前）视为无效，退回熄灭。
  Future<void> toggleAbLoop() async {
    switch (state.abPhase) {
      case AbLoopPhase.off:
        state = state.copyWith(
          abPhase: AbLoopPhase.aMarked,
          abStart: state.position,
        );
      case AbLoopPhase.aMarked:
        final start = state.abStart ?? Duration.zero;
        final end = state.position;
        if (end <= start) {
          state = state.copyWith(
            abPhase: AbLoopPhase.off,
            abStart: null,
            abEnd: null,
          );
          return;
        }
        state = state.copyWith(abPhase: AbLoopPhase.looping, abEnd: end);
        // 立即回 A 开始复读这一段。
        _markSeekIssued(start);
        unawaited(_seekPlayer(start));
        state = state.copyWith(position: start);
      case AbLoopPhase.looping:
        state = state.copyWith(
          abPhase: AbLoopPhase.off,
          abStart: null,
          abEnd: null,
        );
    }
  }

  /// 上一句/下一句：沿 [AudioPlayerState.segmentBoundaries] 跳到相邻的
  /// 分段起点。自动暂停停在句首时，上一句要求 800ms 之外还有更早的边界。
  void goToPreviousSegment() {
    final currentPosition = state.position;
    final boundaries = state.segmentBoundaries;

    if (boundaries.isEmpty) return;

    final previousBoundaries = boundaries
        .where((b) => currentPosition - b > Duration(milliseconds: 800))
        .toList();

    if (previousBoundaries.isNotEmpty) {
      final nearest = previousBoundaries.reduce((a, b) => a > b ? a : b);
      _jumpToSegment(nearest);
    }
  }

  void goToNextSegment() {
    final currentPosition = state.position;
    final boundaries = state.segmentBoundaries;

    if (boundaries.isEmpty) return;

    final nextBoundaries = boundaries.where((b) => b > currentPosition).toList();

    if (nextBoundaries.isNotEmpty) {
      final nearest = nextBoundaries.reduce((a, b) => a < b ? a : b);
      _jumpToSegment(nearest);
    }
  }

  /// 跳句（上一句/下一句、实体键切句）后的播放状态与网页播放器对齐：
  /// 自动暂停开着就起播目标句（`jumpCueAutoplay: "autopause"` —— 逐句精听
  /// 时跳过去不发声等于没跳），关着就保持原状（暂停仍是暂停，方便先翻着看）。
  void _jumpToSegment(Duration target) {
    unawaited(seek(target, autoplay: state.autoPauseMode));
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
    _boundaryHandledAt = null;
    _clearPendingSeek();
    // 上一页的 seek 队列不再有意义：留着只会让新页面的第一次 seek 白等
    // 几秒（见 _seekPlayer 的排队）。
    _seekChain = null;
    // 换书/换页/离开阅读页时把在跑的预取掐掉：半截文件留在 `.part` 里，
    // 下次进来（或下一次 loadAudio）从那里续传，不用白下已下过的部分。
    _cancelPrefetch();
    lastLoadSignature = null;
    _lastAudioUrl = null;
    lastLocalAudioFile = null;
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

  /// 装配音源，**不等整份下载**。
  ///
  /// 缓存完整时直接播本地文件（离线可播、秒开）；否则带鉴权头流式起播 ——
  /// 远端音源只有在本地 fork 过的 audioplayers 上才能带请求头（见
  /// third_party/audioplayers），一个不带头的请求会被多用户服务器 302 到
  /// /login。起播的同时把文件补进缓存目录：缓存是离线播放的根基，影子跟读
  /// 的原句裁剪也从它取片段。
  Future<void> _setAudioSource(
    String audioUrl,
    Map<String, String> authHeaders,
  ) async {
    final cacheFile = await _audioCacheFile(audioUrl);
    if (await _isCacheComplete(cacheFile, audioUrl, authHeaders)) {
      lastLocalAudioFile = cacheFile;
      await _audioPlayer!.setSourceDeviceFile(cacheFile.path);
      return;
    }

    // 手上那份旧的完整文件也先交给影子跟读用，预取会把它更新成新版本。
    final hasStaleCopy = await cacheFile.exists();
    lastLocalAudioFile = hasStaleCopy ? cacheFile : null;
    await _audioPlayer!.setSourceUrl(
      audioUrl,
      headers: authHeaders.isEmpty ? null : authHeaders,
    );
    _prefetchAudio(audioUrl, authHeaders, cacheFile);
  }

  Future<File> _audioCacheFile(String audioUrl) async {
    final cacheDir = await getApplicationCacheDirectory();
    final audioDir = Directory('${cacheDir.path}/audiobooks');
    await audioDir.create(recursive: true);
    return File(
      '${audioDir.path}/audiobook_${_bookId}_${audioUrl.hashCode.abs()}.audio',
    );
  }

  /// 缓存文件是否与远端一致、可以直接播放。
  ///
  /// 探测大小这一步在离线时必然失败 —— 失败不能当成「缓存无效」，得当成
  /// 「网络不可用」，信手上的文件。
  Future<bool> _isCacheComplete(
    File cacheFile,
    String audioUrl,
    Map<String, String> authHeaders,
  ) async {
    if (!await cacheFile.exists()) return false;
    // 离线（服务器已判不可达）就别再发 Range 探测了：它只会白等一个
    // connectTimeout 再失败，让离线开书平白多挂十几秒。
    if (!ServerStatusManager.isReachable) {
      debugPrint('AudioPlayer: probe skipped/unreachable, using cached copy');
      return true;
    }
    final remoteSize = await _probeAudioSize(audioUrl, authHeaders);
    if (remoteSize == null) {
      debugPrint('AudioPlayer: probe failed, using cached copy');
      return true;
    }
    return await cacheFile.length() == remoteSize;
  }

  /// 后台把音频补进缓存目录，补完再交给影子跟读做原句裁剪。
  ///
  /// 中断不再等于白下：[_downloadAudioToFile] 会从 `.part` 已有的字节续传，
  /// 这里再补几次重试，让**一次** loadAudio 就把文件补完，而不是干等下一次
  /// 进这本书（2026-10-10 diag.log：64MB 下到 52MB 被掐，下一次 loadAudio
  /// 又从 0 下了一遍，白扔 50 多 MB）。失败静默：在线流式播放不受影响。
  void _prefetchAudio(
    String audioUrl,
    Map<String, String> authHeaders,
    File target,
  ) {
    final key = '$_bookId|$audioUrl';
    if (!_prefetchingAudio.add(key)) return;
    // 同一时刻只跑一条：换书/换页时把上一条掐掉，别让旧书的几十 MB
    // 还在后台跟新书的抢带宽。
    _cancelPrefetch();
    final token = CancelToken();
    _prefetchCancel = token;
    _prefetchKey = key;
    unawaited(() async {
      try {
        for (var attempt = 1; ; attempt++) {
          try {
            await _downloadAudioToFile(
              audioUrl,
              authHeaders,
              target,
              cancelToken: token,
            );
            if (key == '$_bookId|$_lastAudioUrl') {
              lastLocalAudioFile = target;
            }
            return;
          } catch (e) {
            // 被主动掐掉（换书/换页）不是失败，别重试也别刷日志。
            if (token.isCancelled) return;
            if (attempt >= _prefetchMaxAttempts) rethrow;
            debugPrint(
              'AudioPlayer: 预取中断（第 $attempt 次），'
              '${_prefetchRetryDelay.inSeconds}s 后从已下字节续传: $e',
            );
            await Future<void>.delayed(_prefetchRetryDelay);
            if (token.isCancelled) return;
          }
        }
      } catch (e) {
        debugPrint('AudioPlayer: 后台预取音频失败（不影响在线播放）: $e');
      } finally {
        // 只有这条还是"当前那条"时才清键：被掐掉的那条收尾时，新的那条
        // 可能已经占用了同一个键，清掉它等于让去重失效。
        if (identical(_prefetchCancel, token)) {
          _prefetchingAudio.remove(key);
          _prefetchCancel = null;
          _prefetchKey = null;
        }
      }
    }());
  }

  /// 预取的最大尝试次数与两次尝试之间的间隔（从已下字节续传，代价很小）。
  static const int _prefetchMaxAttempts = 3;
  static const Duration _prefetchRetryDelay = Duration(seconds: 3);

  /// 掐掉在跑的预取（换书、换页、离开阅读页）。
  void _cancelPrefetch() {
    final token = _prefetchCancel;
    final key = _prefetchKey;
    _prefetchCancel = null;
    _prefetchKey = null;
    // 同步摘掉去重键：紧接着的同名预取不能被上一次的 finally 抢跑，否则新的
    // 那份会被当成"已经在下了"直接跳过，缓存就永远补不上了。
    if (key != null) _prefetchingAudio.remove(key);
    token?.cancel();
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

  /// 把音频下到 [target]，**断点续传**。
  ///
  /// 服务端的 `/useraudio/stream/<id>` 支持 Range（`_send_audio_range_aware`），
  /// 所以中断后从 `${target.path}.part` 已有的字节接着下，而不是删掉重来：
  /// 2026-10-10 的 diag.log 里一本 64MB 的有声书下到 `bs=52826112` 被掐，
  /// 下一次 loadAudio 又从 0 下了一遍（`bs=64231987`），白扔 50 多 MB。
  ///
  /// 续传只在服务端**确实按我们的起点回了 206** 时才追加（判定见
  /// [resumeWriteOffset]）；回 200（不支持 Range、或 `?v=` 换了文件）就从头
  /// 重写 —— 否则会把整份内容接在半截文件后面，得到一个长度对、内容坏的缓存。
  Future<void> _downloadAudioToFile(
    String url,
    Map<String, String> authHeaders,
    File target, {
    bool retriedAfterLogin = false,
    CancelToken? cancelToken,
  }) async {
    final tmp = File('${target.path}.part');
    final existing = await tmp.exists() ? await tmp.length() : 0;
    IOSink? sink;
    try {
      final response = await _audioDio.get<ResponseBody>(
        url,
        options: Options(
          headers: {
            ...authHeaders,
            if (existing > 0) 'Range': 'bytes=$existing-',
          },
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
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
            cancelToken: cancelToken,
          );
          return;
        }
        throw const ServerLoginRequiredException();
      }
      final offset = resumeWriteOffset(
        existing: existing,
        status: status,
        contentRange: response.headers.value('content-range'),
      );
      debugPrint(
        'AudioPlayer: 下载音频 $url status=$status '
        '已有=$existing 起点=$offset',
      );
      sink = tmp.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      await sink.addStream(response.data!.stream);
      await sink.flush();
      await sink.close();
      sink = null;
      // 下完再对一次长度：续传的起点是"我们手上有什么"，服务端可能已经换了
      // 文件，长度对不上说明这份是拼出来的，不能留。
      final total =
          contentRangeTotal(response.headers.value('content-range')) ??
          _intHeader(response.headers.value('content-length'));
      final actual = await tmp.length();
      if (total != null && actual != total) {
        await tmp.delete();
        throw StateError('音频下载长度不符: $actual != $total');
      }
      await tmp.rename(target.path);
    } catch (_) {
      // **不删** `.part`：它就是下次续传的起点。半截文件不会被当成缓存用
      // （`_isCacheComplete` 只认最终文件名，且长度要对上远端）。
      // 关掉 sink 是为了把已写入的部分刷到磁盘，别让下一次续传从头开始。
      try {
        await sink?.close();
      } catch (_) {}
      rethrow;
    }
  }

  int? _intHeader(String? value) =>
      value == null ? null : int.tryParse(value.trim());

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
      // 字段，而不是带一个空列表。规则见 bookmarksToPost。句子分段边界
      // 在 segmentBoundaries 里，从来不进书签写回。
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
