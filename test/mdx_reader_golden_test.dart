import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/mdx_reader.dart';

/// 用服务器上真实的《小学馆V2日汉辞典》MDX（LZO 压缩、UTF-8）做金标，
/// 锁住纯 Dart MDX 解析器的三个关键行为：头部解析、LZO 块解压、记录
/// 分段（key 的 record offset 切分定义）。转换脚本
/// （lute-v3 tools/mdx_to_sqlite.py，python 实现）产出的 69,425 词条
/// 就是同一文件的解析结果，可交叉对照。
///
/// 跳过条件：文件不存在（本地开发机没有该词典文件）。
void main() {
  const mdxPath = '/opt/dict_build/shogakukan_v2.mdx';
  final file = File(mdxPath);

  test('解析真实 MDX：头部 + LZO 块 + 记录切分', () {
    if (!file.existsSync()) {
      print('跳过：$mdxPath 不存在');
      return;
    }
    final reader = MdxReader.fromFile(mdxPath);

    // 头部：该文件是老格式 MDX 1.2 + UTF-16 + LZO（最挑剔的组合）。
    // （1.2 时代无标题的文件 Title 就是字面 'Title (No HTML code allowed)'，
    // 真名在文件名里，不断言。）
    expect(reader.encoding, 'UTF-16');
    expect(reader.version, 1.2);

    // 条目总数与 python 转换脚本一致
    expect(reader.entryCount, 70307);

    // 记录流：抽几个已知的词头 + 定义片段
    final found = <String, String>{};
    var count = 0;
    for (final entry in reader.entries()) {
      count++;
      final key = MdxReader.cleanKey(entry.key);
      found.putIfAbsent(key, () => MdxReader.cleanDefinition(entry.value));
      if (found.containsKey('たのしい') && found.containsKey('ひさしぶり')) {
        break;
      }
      if (count > 120000) break; // 兜底，防死循环
    }

    // 70307 个键按假名序遍历，两个目标词都在 4 万条之后才出现
    expect(count, greaterThan(40000), reason: '应解析出绝大多数词条');
    expect(found.containsKey('たのしい'), isTrue);
    expect(found['たのしい']!, contains('楽しい'));
    expect(found['たのしい']!, contains('愉快'));
    expect(found.containsKey('ひさしぶり'), isTrue);
    expect(found['ひさしぶり']!, contains('久し振り'));
    expect(found['ひさしぶり']!, contains('好久'));
  });

  test('cleanKey 剥 HTML 链接包装', () {
    expect(
      MdxReader.cleanKey('<a href="entry://久し振り">久し振り</a>'),
      '久し振り',
    );
    expect(MdxReader.cleanKey('  箱 '), '箱');
  });

  test('cleanDefinition：HTML 转纯文本并保留换行', () {
    final text = MdxReader.cleanDefinition(
      '<div>愉快yúkuài<br/>快乐<div>例：<br/>～クリスマス</div></div>',
    );
    expect(text, contains('愉快yúkuài\n快乐'));
    expect(text, contains('～クリスマス'));
    expect(text.contains('<'), isFalse);
  });
}
