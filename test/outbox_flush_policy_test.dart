import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';
import 'package:song_mobile/core/outbox/outbox_flush_policy.dart';

// flush 的决策规则全部抽成了纯函数,就是为了能这样穷举 —— 不用 store、不用
// 网络、不用 ProviderContainer。重试节奏错一次的代价是「用户的编辑永远发不出去」
// 或者「离线时每 5 秒锤一次服务器」,两种都不该靠肉眼看日志来验。
void main() {
  group('planFlush', () {
    test('按 seq 升序发出(用户的动作有因果顺序)', () {
      // 用户先设了 3,又改成 99。倒序发的话服务端最后留下的是 3。
      final intents = [
        _edit(termId: 1, seq: 5),
        _edit(termId: 2, seq: 1),
        _edit(termId: 3, seq: 3),
      ];

      final planned = planFlush(intents, nowMs: 1000);

      expect(planned.map((i) => i.seq), [1, 3, 5]);
    });

    test('还没到重试时间的跳过', () {
      final intents = [
        _edit(termId: 1, seq: 1, nextAttemptAtMs: 500),
        _edit(termId: 2, seq: 2, nextAttemptAtMs: 5000),
      ];

      final planned = planFlush(intents, nowMs: 1000);

      expect(planned.map((i) => i.seq), [1]);
    });

    test('nextAttemptAtMs 恰好等于 now 时算到期(边界含等号)', () {
      final intents = [_edit(termId: 1, seq: 1, nextAttemptAtMs: 1000)];

      expect(planFlush(intents, nowMs: 1000), hasLength(1));
    });

    test('已永久失败的跳过,不再骚扰服务器', () {
      final intents = [
        _edit(termId: 1, seq: 1),
        _edit(termId: 2, seq: 2, failed: true),
      ];

      final planned = planFlush(intents, nowMs: 1000);

      expect(planned.map((i) => i.seq), [1]);
    });

    test('超过 limit 时截断,且截断的是队尾(先到先发)', () {
      final intents = [
        for (var i = 1; i <= 5; i++) _edit(termId: i, seq: i),
      ];

      final planned = planFlush(intents, nowMs: 1000, limit: 2);

      expect(planned.map((i) => i.seq), [1, 2]);
    });

    test('空输入返回空', () {
      expect(planFlush(const [], nowMs: 1000), isEmpty);
    });
  });

  group('nextRetryDelay', () {
    test('从 5 秒起翻倍', () {
      expect(nextRetryDelay(0), const Duration(seconds: 5));
      expect(nextRetryDelay(1), const Duration(seconds: 10));
      expect(nextRetryDelay(2), const Duration(seconds: 20));
      expect(nextRetryDelay(3), const Duration(seconds: 40));
    });

    test('封顶在 300 秒(不能变成永远不再试)', () {
      expect(nextRetryDelay(6), const Duration(seconds: 300));
      expect(nextRetryDelay(7), const Duration(seconds: 300));
      expect(nextRetryDelay(100), const Duration(seconds: 300));
    });

    test('超大 attempts 不会溢出成负数或荒谬时长', () {
      // 这是真实会踩的坑:1 << 30 之后是负数,Duration 会变成负的,于是
      // nextAttemptAtMs 落在过去 —— 退避直接失效,变成死循环猛发。
      for (final attempts in [8, 9, 30, 1000, 1 << 40]) {
        final delay = nextRetryDelay(attempts);
        expect(delay.inSeconds, greaterThan(0));
        expect(delay.inSeconds, lessThanOrEqualTo(maxRetrySeconds));
      }
    });

    test('负数 attempts 当作 0', () {
      expect(nextRetryDelay(-5), const Duration(seconds: 5));
    });

    test('单调不减', () {
      var previous = Duration.zero;
      for (var attempts = 0; attempts <= 12; attempts++) {
        final delay = nextRetryDelay(attempts);
        expect(
          delay.inSeconds,
          greaterThanOrEqualTo(previous.inSeconds),
          reason: 'attempts=$attempts 时退避变短了',
        );
        previous = delay;
      }
    });
  });

  group('isPermanentFailure', () {
    test('没有 HTTP 应答(超时/断连/DNS)一律是暂时的', () {
      // 这是整个离线能力的地基:null statusCode 意味着「根本没问到服务器」,
      // 绝不能被判成永久失败 —— 否则在地铁里点一下就等于把编辑扔了。
      for (final attempts in [0, 1, 5, 9]) {
        expect(
          isPermanentFailure(null, attempts: attempts),
          isFalse,
          reason: 'attempts=$attempts 时把断连判成了永久失败',
        );
      }
    });

    test('4xx 里「重放也修不好」的那几个判永久', () {
      for (final code in [400, 403, 404, 410, 422]) {
        expect(isPermanentFailure(code, attempts: 1), isTrue, reason: '$code');
      }
    });

    test('5xx 和 429 是暂时的(服务器自己会好)', () {
      for (final code in [500, 502, 503, 504, 429]) {
        expect(isPermanentFailure(code, attempts: 1), isFalse, reason: '$code');
      }
    });

    test('401 不是永久的 —— 那是要重新登录,不是要丢掉编辑', () {
      // 会话过期由调用方按 needsLogin 处理,不能让重试预算把它吃掉。
      expect(isPermanentFailure(401, attempts: 1), isFalse);
    });

    test('重试预算用尽即判永久', () {
      expect(isPermanentFailure(null, attempts: maxFlushAttempts - 1), isFalse);
      expect(isPermanentFailure(null, attempts: maxFlushAttempts), isTrue);
    });

    test('预算用尽优先于状态码判断', () {
      expect(isPermanentFailure(503, attempts: maxFlushAttempts), isTrue);
    });
  });
}

PendingIntent _edit({
  required int termId,
  required int seq,
  int attempts = 0,
  int nextAttemptAtMs = 0,
  bool failed = false,
}) => TermEditIntent(
  termId: termId,
  status: '3',
  seq: seq,
  attempts: attempts,
  nextAttemptAtMs: nextAttemptAtMs,
  failed: failed,
);
