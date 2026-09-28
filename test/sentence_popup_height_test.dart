import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/dictionary_service.dart';

/// 句子翻译弹窗高度换算的契约测试。
///
/// 背景：弹窗里是有道这类会随 CSS 视口宽度整体放大的页面。高度写死 300
/// 逻辑像素时，宽视口设备（Leaf 5C：300dpi，webview 宽 634）只能露出手机上
/// 2/3 的内容，翻译结果被顶到折叠线以下。resolvePopupHeight 负责按宽度
/// 等比换算，并且**只放大不缩小**，保证手机行为不变。
void main() {
  group('resolvePopupHeight', () {
    test('手机宽度（≤ 基准 440）原样返回，行为不变', () {
      for (final width in <double>[320, 371, 412, 440]) {
        expect(
          DictionaryService.resolvePopupHeight(
            DictionaryService.defaultPopupHeight,
            width,
          ),
          DictionaryService.defaultPopupHeight,
          reason: 'webview 宽 $width 不该被改动',
        );
      }
    });

    test('Leaf 5C（webview 宽 634）按比例加高到 454', () {
      expect(
        DictionaryService.resolvePopupHeight(
          DictionaryService.defaultPopupHeight,
          634,
        ),
        454,
      );
    });

    test('用户自己调过的高度也按同一比例换算', () {
      final phone = DictionaryService.resolvePopupHeight(200, 440);
      final leaf = DictionaryService.resolvePopupHeight(200, 634);
      expect(phone, 200);
      expect(leaf, greaterThan(phone));
      expect(leaf, closeTo(200 * 634 / 440 * 1.05, 1));
    });

    test('超过上限时夹到 maxPopupHeight', () {
      expect(
        DictionaryService.resolvePopupHeight(
          DictionaryService.maxPopupHeight,
          634,
        ),
        DictionaryService.maxPopupHeight,
      );
    });

    test('宽度拿不到（0）时不换算，避免首帧算出一个荒唐值', () {
      expect(
        DictionaryService.resolvePopupHeight(
          DictionaryService.defaultPopupHeight,
          0,
        ),
        DictionaryService.defaultPopupHeight,
      );
    });
  });
}
