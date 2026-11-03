import '../models/text_item.dart';

/// 多词选区拼成词条文本。
///
/// 选区是按 `order` 排好的一串 token —— Lute 把空格、标点也当成 token，
/// 所以英文词与词之间的空格本来就在选区里。拼接时只能「收边 + 折叠」，
/// 不能整体删空白：删掉那个空格，词卡里的 `roll off` 就变成 `rolloff`。
///
/// 中文、日文这类词间不加空格的语言，选区里没有空白 token，折叠是空操作，
/// 不会凭空插空格。
String buildMultiTermText(Iterable<TextItem> items) {
  final joined = StringBuffer();
  for (final item in items) {
    joined.write(item.displayText);
  }
  // 连续空白折叠成一个（保留原来的字符，全角空格不会被换成半角），
  // 再裁掉选区首尾 —— 长按常从行首缩进或上一行尾开始。
  final collapsed = joined.toString().replaceAllMapped(
    RegExp(r'(\s)\s+'),
    (match) => match[1]!,
  );
  return collapsed.trim();
}

/// 页面 span 的 `data-order` 换成 token 下标。
///
/// EPUB 阅读页给 span 打的是 `tokenIndex * 1000 + piece`（一个 token 被
/// 行内标签切开时会渲染成多个 span，乘 1000 才保证每个 span 的 order 唯一；
/// 见 lute-epub-reader.js 的 makeSpan）。较早写入的离线包若还是旧的纯
/// token 下标，[usesPieceShift] 为 false，原样返回。
///
/// 同一个 token 的多个 piece 会落到同一个下标，调用方按下标去重即可。
int tokenIndexForSpanOrder(int spanOrder, {required bool usesPieceShift}) =>
    usesPieceShift ? spanOrder ~/ 1000 : spanOrder;

/// 把按 span 回传的选区补成 page 上的完整 token 区间。
///
/// EPUB 阅读页不给空白 token 建 span（两词之间的空格只是页面里的原始文本
/// 节点），所以页面回传的 payload 里没有词间空格；只拼 payload 就会把
/// `roll off` 粘成 `rolloff`。页面对应的完整 token 流在 [pageItems] 里，
/// 这里按 payload 的最小/最大 `order` 取闭区间，缺的 token 从模型补上，
/// 模型也没有的才用 payload 自己兜底。
///
/// `order` 是 token 在页面里的下标（唯一、连续），这也是 Flutter 渲染的
/// 文本路径选词时用的同一个区间语义。
List<TextItem> selectionItemsInOrderRange({
  required Iterable<TextItem> pageItems,
  required Map<int, TextItem> payloadsByOrder,
}) {
  if (payloadsByOrder.isEmpty) return const <TextItem>[];
  final byOrder = <int, TextItem>{};
  for (final item in pageItems) {
    byOrder.putIfAbsent(item.order, () => item);
  }
  final orders = payloadsByOrder.keys.toList()..sort();
  final result = <TextItem>[];
  for (var order = orders.first; order <= orders.last; order++) {
    final item = byOrder[order] ?? payloadsByOrder[order];
    if (item != null) result.add(item);
  }
  return result;
}
