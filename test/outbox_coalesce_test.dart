import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/outbox/models/pending_intent.dart';

// coalesce() 是纯函数,也是整个 outbox 里唯一决定「两个意图怎么合并」的地方。
// flush 之所以完全不用考虑顺序,就是因为合并已经把顺序变得无关紧要了 —— 所以
// 这里的每条规则都值得钉住。
void main() {
  group('coalesceKey', () {
    test('三类意图的 key 互不冲突(同 id 也不会串)', () {
      // 前缀不是装饰:term 1 和 book 1 page 1 如果 key 撞了,一次双击会把
      // 另一条待同步的翻页记录吃掉。
      final termEdit = TermEditIntent(termId: 1, status: '3', seq: 0);
      final termCreate = TermCreateIntent(
        langId: 1,
        text: '1',
        formData: const {},
        seq: 0,
      );
      final pageDone = PageDoneIntent(
        bookId: 1,
        pageNum: 1,
        markRead: true,
        markKnown: false,
        seq: 0,
      );

      expect(
        {termEdit.coalesceKey, termCreate.coalesceKey, pageDone.coalesceKey},
        hasLength(3),
      );
    });
  });

  group('TermEditIntent 合并', () {
    test('后一次双击只改 status,前一次的完整表单快照要留下', () {
      // 「先打开词条表单填了翻译并保存,再双击这个词改状态」是最常见的组合。
      // 如果后一个裸 status 意图把 formData 顶掉,flush 就得重新去拉表单 ——
      // 拉回来的是服务端当前的字段,不是用户刚才填的那些。
      final saved = TermEditIntent(
        termId: 7,
        status: '1',
        formData: const {'term': '猫', 'translation': 'cat'},
        seq: 3,
      );
      final cycled = TermEditIntent(termId: 7, status: '99', seq: 4);

      final merged = coalesce(saved, cycled) as TermEditIntent;

      expect(merged.status, '99', reason: '状态取最新的一次');
      expect(merged.formData, saved.formData, reason: '表单快照要继承下来');
      expect(merged.seq, 4);
    });

    test('后一次自己带表单时,用后一次的(用户改的就是它)', () {
      final older = TermEditIntent(
        termId: 7,
        status: '1',
        formData: const {'term': '猫', 'translation': 'cat'},
        seq: 1,
      );
      final newer = TermEditIntent(
        termId: 7,
        status: '3',
        formData: const {'term': '猫', 'translation': 'neko'},
        seq: 2,
      );

      final merged = coalesce(older, newer) as TermEditIntent;

      expect(merged.formData, newer.formData);
    });

    test('langId 同样只在后一次带的时候才覆盖', () {
      final older = TermEditIntent(termId: 7, status: '1', langId: 42, seq: 1);
      final newer = TermEditIntent(termId: 7, status: '3', seq: 2);

      final merged = coalesce(older, newer) as TermEditIntent;

      expect(merged.langId, 42);
    });

    test('合并会重置重试预算(seq 归零、failed 清掉)', () {
      // 合并结果以 newer 为底,而 newer 是刚构造出来的,attempts=0/failed=false。
      // 这是有意的:用户刚刚又表达了一次意图,应该立刻重试,而不是继续背着
      // 上一轮的退避时间。
      final exhausted = TermEditIntent(
        termId: 7,
        status: '1',
        seq: 1,
        attempts: 9,
        nextAttemptAtMs: 999999,
        failed: true,
      );
      final fresh = TermEditIntent(termId: 7, status: '3', seq: 2);

      final merged = coalesce(exhausted, fresh) as TermEditIntent;

      expect(merged.attempts, 0);
      expect(merged.nextAttemptAtMs, 0);
      expect(merged.failed, isFalse);
    });
  });

  group('PageDoneIntent 合并', () {
    test('markKnown 不会被随后的 markRead 抹掉(必须 OR)', () {
      // 这条是真正会出 bug 的场景:_markPageKnown() 打完 All Known 之后立刻
      // 翻到下一页,而翻页会为**同一页**发一条 markRead。如果按「后者胜」,
      // 用户刚点的 All Known 就没了。
      final allKnown = PageDoneIntent(
        bookId: 5,
        pageNum: 12,
        markRead: false,
        markKnown: true,
        seq: 10,
      );
      final turnPage = PageDoneIntent(
        bookId: 5,
        pageNum: 12,
        markRead: true,
        markKnown: false,
        seq: 11,
      );

      final merged = coalesce(allKnown, turnPage) as PageDoneIntent;

      expect(merged.markKnown, isTrue, reason: 'All Known 必须活下来');
      expect(merged.markRead, isTrue);
    });

    test('反过来也成立:先翻页再 All Known,两个标记都在', () {
      final turnPage = PageDoneIntent(
        bookId: 5,
        pageNum: 12,
        markRead: true,
        markKnown: false,
        seq: 10,
      );
      final allKnown = PageDoneIntent(
        bookId: 5,
        pageNum: 12,
        markRead: false,
        markKnown: true,
        seq: 11,
      );

      final merged = coalesce(turnPage, allKnown) as PageDoneIntent;

      expect(merged.markRead, isTrue);
      expect(merged.markKnown, isTrue);
    });

    test('不同页不合并(靠 coalesceKey,由 service 保证)', () {
      final p12 = PageDoneIntent(
        bookId: 5,
        pageNum: 12,
        markRead: true,
        markKnown: false,
        seq: 1,
      );
      final p13 = PageDoneIntent(
        bookId: 5,
        pageNum: 13,
        markRead: true,
        markKnown: false,
        seq: 2,
      );

      expect(p12.coalesceKey, isNot(p13.coalesceKey));
    });
  });

  group('JSON 往返', () {
    test('三类意图都能 encode/decode 回来,字段不丢', () {
      final intents = <PendingIntent>[
        TermEditIntent(
          termId: 7,
          status: '3',
          formData: const {'term': '猫', 'translation': 'cat'},
          langId: 42,
          seq: 1,
          attempts: 2,
          nextAttemptAtMs: 1234,
        ),
        TermCreateIntent(
          langId: 42,
          text: '犬',
          formData: const {'term': '犬'},
          seq: 2,
        ),
        PageDoneIntent(
          bookId: 5,
          pageNum: 12,
          markRead: true,
          markKnown: true,
          seq: 3,
          failed: true,
        ),
      ];

      for (final intent in intents) {
        final back = PendingIntent.decode(intent.encode());

        expect(back.runtimeType, intent.runtimeType);
        expect(back.seq, intent.seq);
        expect(back.attempts, intent.attempts);
        expect(back.nextAttemptAtMs, intent.nextAttemptAtMs);
        expect(back.failed, intent.failed);
        expect(back.coalesceKey, intent.coalesceKey);
      }
    });

    test('term_edit 的 formData 嵌套 map 能原样回来', () {
      // formData 会直接作为 POST body 的一部分发出去,丢字段就等于把词条的
      // 翻译/标签/图片清空。
      final intent = TermEditIntent(
        termId: 7,
        status: '1',
        formData: const {
          'term': '猫',
          'translation': 'cat',
          'tags': ['animal', 'noun'],
        },
        seq: 1,
      );

      final back = PendingIntent.decode(intent.encode()) as TermEditIntent;

      expect(back.formData, intent.formData);
    });

    test('未知 kind 抛 FormatException(而不是静默当成空意图)', () {
      expect(
        () => PendingIntent.decode('{"kind":"nope","seq":1}'),
        throwsFormatException,
      );
    });
  });
}
