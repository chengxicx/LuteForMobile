// 「刚发出的 seek 落地了没有」的判定 —— 直接决定按"下一句"到底跳不跳得过去。
//
// 起因（2026-10-10，手机实测）：自动暂停/循环开着时，按播放条左边的"下一句"，
// 播放头 54:19 → 54:23 之后又被拽回 54:19。根因是远程音源的 seekTo 要重新拉
// 一段 HTTP Range 才生效，期间 onPositionChanged 推来的还是旧位置（迟到回声）；
// 旧的 600ms 固定屏蔽窗口一过，旧位置就被当成真实前进，跨段判定据此把播放头
// 拉回旧句。所以判定改成"播放器报出的位置真的到达目标"。
//
// 这里钉住的就是这个判定的三个关键点：**方向**（往回跳不能用"往前走"的规则）、
// **放弃等待的上限**（不设上限会把播放条永久冻住），以及**谁有权记在途 seek**
// （没下发 seek 却记了，等于把播放条冻到超时为止 —— 2026-10-10 真机在普通
// 播放模式下撞到过：跨过第一个句尾后 12 秒不动）。

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/pending_seek.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('seekHasLanded —— 往前走', () {
    final origin = ms(1000);
    final target = ms(5000);

    test('还在旧位置（迟到回声）→ 没落地', () {
      expect(
        seekHasLanded(position: ms(1200), target: target, origin: origin),
        isFalse,
      );
    });

    test('到达目标 → 落地', () {
      expect(
        seekHasLanded(position: target, target: target, origin: origin),
        isTrue,
      );
    });

    test('差几十毫秒的取整差也算落地（容差内）', () {
      expect(
        seekHasLanded(
          position: ms(4700),
          target: target,
          origin: origin,
          tolerance: ms(400),
        ),
        isTrue,
      );
      expect(
        seekHasLanded(
          position: ms(4500),
          target: target,
          origin: origin,
          tolerance: ms(400),
        ),
        isFalse,
      );
    });

    test('冲过头（解码器多走了一点）仍然算落地', () {
      expect(
        seekHasLanded(position: ms(5300), target: target, origin: origin),
        isTrue,
      );
    });
  });

  group('seekHasLanded —— 往回跳（"上一句"）', () {
    final origin = ms(5000);
    final target = ms(1000);

    test('还在旧位置（迟到回声）→ 没落地，不能被判成"起点本来就比目标大"', () {
      // 这是最容易写错的一条：方向判错的话这里会返回 true，迟到的旧位置
      // 立刻被放行，跨段判定又把播放头拽回去 —— 用户看到的就是"点了没反应"。
      expect(
        seekHasLanded(position: ms(4800), target: target, origin: origin),
        isFalse,
      );
    });

    test('回到目标 → 落地', () {
      expect(
        seekHasLanded(position: target, target: target, origin: origin),
        isTrue,
      );
    });

    test('还在目标之后一点（容差内）也算落地', () {
      expect(
        seekHasLanded(
          position: ms(1350),
          target: target,
          origin: origin,
          tolerance: ms(400),
        ),
        isTrue,
      );
      expect(
        seekHasLanded(
          position: ms(1500),
          target: target,
          origin: origin,
          tolerance: ms(400),
        ),
        isFalse,
      );
    });
  });

  group('evaluatePendingSeek', () {
    test('没有在途 seek 时不该被调用；调用则按位置判定', () {
      // target == origin 视为"往回"分支，位置就在原地 → 落地。
      expect(
        evaluatePendingSeek(
          position: ms(1000),
          target: ms(1000),
          origin: ms(1000),
          elapsed: Duration.zero,
        ),
        PendingSeekVerdict.proceed,
      );
    });

    test('seek 没落地且在超时内 → pending（整条位置事件丢弃）', () {
      expect(
        evaluatePendingSeek(
          position: ms(1200),
          target: ms(5000),
          origin: ms(1000),
          elapsed: ms(800),
        ),
        PendingSeekVerdict.pending,
      );
    });

    test('seek 落地 → proceed', () {
      expect(
        evaluatePendingSeek(
          position: ms(5000),
          target: ms(5000),
          origin: ms(1000),
          elapsed: ms(800),
        ),
        PendingSeekVerdict.proceed,
      );
    });

    test('等太久（seek 失败/音源被换掉）→ expired，别把播放条永久冻住', () {
      expect(
        evaluatePendingSeek(
          position: ms(1200),
          target: ms(5000),
          origin: ms(1000),
          elapsed: const Duration(seconds: 12) + ms(1),
        ),
        PendingSeekVerdict.expired,
      );
    });

    test('慢到超过超时但确实落了地 → 仍按落地收尾，不记成"放弃等待"', () {
      expect(
        evaluatePendingSeek(
          position: ms(5000),
          target: ms(5000),
          origin: ms(1000),
          elapsed: const Duration(seconds: 30),
        ),
        PendingSeekVerdict.proceed,
      );
    });
  });

  group('segmentBoundaryAction —— 句尾跨界该不该 seek', () {
    test('循环开 → 跳回句首继续播（循环优先于自动暂停）', () {
      expect(
        segmentBoundaryAction(loopMode: true, autoPauseMode: true),
        SegmentBoundaryAction.loopBack,
      );
      expect(
        segmentBoundaryAction(loopMode: true, autoPauseMode: false),
        SegmentBoundaryAction.loopBack,
      );
    });

    test('只开自动暂停 → 跳回句首并停住', () {
      expect(
        segmentBoundaryAction(loopMode: false, autoPauseMode: true),
        SegmentBoundaryAction.pauseBack,
      );
    });

    test('两个都关（普通播放）→ 不下发 seek，因而也不许记在途 seek', () {
      // 2026-10-10 真机回归：这里曾经无条件记下"在途 seek = 句首"，而句首在
      // 播放头后面，seekHasLanded 对往回跳要求 position <= 句首 + 容差 ——
      // 永远不成立，于是每条位置事件都被丢掉，进度条冻 12 秒后突然跳到
      // 13.149s（loop=off autoPause=off 的普通播放最容易撞上）。
      expect(
        segmentBoundaryAction(loopMode: false, autoPauseMode: false),
        SegmentBoundaryAction.keepPlaying,
      );
      // 反向钉住上面那段话：句首在播放头后面时，位置事件确实判"没落地"。
      expect(
        evaluatePendingSeek(
          position: ms(1012),
          target: Duration.zero,
          origin: Duration.zero,
          elapsed: ms(1000),
        ),
        PendingSeekVerdict.pending,
        reason: '所以 keepPlaying 分支绝不能调 _markSeekIssued',
      );
    });
  });
}
