import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/follow_scroll.dart';

void main() {
  // 视口 700，锚点 0.35 → 245px；舒适区 [20%, 75%] → [140, 525]。
  const vh = 700.0;
  double? target({
    required double top,
    required double bottom,
    double current = 0,
    double max = 2000,
    double min = 0,
  }) => followScrollTarget(
    itemTop: top,
    itemBottom: bottom,
    viewportHeight: vh,
    currentOffset: current,
    minScrollExtent: min,
    maxScrollExtent: max,
  );

  test('高亮行在舒适区内不动（不再每句整体上移）', () {
    expect(target(top: 350, bottom: 390), isNull);
    expect(target(top: 480, bottom: 520), isNull);
  });

  test('掉到舒适区下方才滚，且落到 35% 锚点', () {
    expect(target(top: 600, bottom: 640), 355.0);
  });

  test('高亮行回到舒适区上方时，往下滚到锚点', () {
    expect(target(top: 20, bottom: 60, current: 600), 375.0);
  });

  test('页末：目标超出 max 且末句完整可见时不动（不跳到中间）', () {
    expect(target(top: 620, bottom: 660, current: 800, max: 900), isNull);
  });

  test('页末但末句被裁时，最多滚到底', () {
    expect(target(top: 690, bottom: 730, current: 700, max: 900), 900.0);
  });

  test('目标小于 min 时夹到顶部', () {
    expect(target(top: 20, bottom: 60, current: 30, min: 0), 0.0);
  });

  test('视口高度无效时不动', () {
    expect(
      followScrollTarget(
        itemTop: 600,
        itemBottom: 640,
        viewportHeight: 0,
        currentOffset: 0,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
      ),
      isNull,
    );
  });
}
