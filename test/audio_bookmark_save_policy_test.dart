// 书签写回策略的契约测试：一次保存请求该不该带上 `bookmarks` 字段。
//
// 这条规则是"书签被清空"这个 bug 的最后一段防线。前两段（页面能读到书签、
// 读到 null 时能区分）在 `audio_bookmarks_roundtrip_test.dart` 里；
// 这里管的是**什么时候允许写**。
//
// 之所以单独成文件而不是塞进 provider 的测试里：决定写不写的逻辑是纯函数
// （`bookmarksToPost`），把它拎出来就能钉住，不必把 audioplayers 的平台通道
// 拖进单元测试。同目录的 `player_lifecycle.dart` 是同一个套路。
//
// 背景（2026-09-27 Leaf 5C 实测）：
//   * 全库没有任何一本书还剩书签 —— 旧的 `const []` 默认值每 2 秒覆盖一次；
//   * 修好"读"之后仍有第二条破坏路径：阅读页整页有 14 天 TTL 的 Hive 缓存
//     （`PageCacheService`，`_ttl = Duration(days: 14)`），
//     `LUTE_YT_DATA.bookmarks` 是页面的一部分。实测把库里的书签改成 250、
//     重开 app，app 回写的是**缓存里的旧值** 86.989，不是 250。
//     若自动保存也带书签，web 端新加的书签就会被十几天的旧快照覆盖。

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/player_save_policy.dart';

void main() {
  group('bookmarksToPost', () {
    test('自动保存不带书签，哪怕列表是加载到的', () {
      // 2 秒一次的自动保存只写进度。带上书签就会用缓存里的旧快照
      // 覆盖服务端较新的列表。
      expect(
        bookmarksToPost(
          userEdited: false,
          authoritative: true,
          bookmarks: const [86.989, 250.0],
        ),
        isNull,
        reason: 'null = 不带这个键 = 服务端别动库里的值',
      );
    });

    test('用户加/删书签时带上，且内容就是当前列表', () {
      expect(
        bookmarksToPost(
          userEdited: true,
          authoritative: true,
          bookmarks: const [86.989, 250.0],
        ),
        const [86.989, 250.0],
      );
    });

    test('用户删掉最后一个书签时带的是空列表，不是 null', () {
      // 这是"空列表"唯一该出现的地方：用户明确删掉了最后一个书签，
      // 服务端应当收到空列表并据此清空。若这里返回 null，书签就删不掉了。
      final posted = bookmarksToPost(
        userEdited: true,
        authoritative: true,
        bookmarks: const [],
      );

      expect(posted, isNotNull);
      expect(posted, isEmpty);
    });

    test('页面没给过书签时，用户编辑也不写回', () {
      // authoritative 为 false 表示"页面从没告诉我们书签是什么"。
      // 此时写回任何值都是在替服务端做它没授权我们做的决定 ——
      // 宁可这次编辑不落库，也不能拿一个我们没读到的列表去覆盖。
      expect(
        bookmarksToPost(
          userEdited: true,
          authoritative: false,
          bookmarks: const [86.989],
        ),
        isNull,
      );
    });

    test('两个条件都不成立时同样不写', () {
      expect(
        bookmarksToPost(
          userEdited: false,
          authoritative: false,
          bookmarks: const [],
        ),
        isNull,
      );
    });
  });
}
