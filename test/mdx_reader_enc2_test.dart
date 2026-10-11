import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/mdx_reader.dart';

/// `Encrypted=2` 的真实词典金标。这类文件头部写着 `Encrypted="2"`，key block
/// info 被一层可推导密钥的异或混淆包住——解析器以前在头部就直接拒收，所以
/// mdict.org 上大多数 MDX 2.0 都装不进来。
///
/// 夹具来自 mdict.org 的三本真实词典，覆盖 `Encrypted=2` 下两种编码：
/// 《日本語表現文型辞典》（UTF-16、1 个 key block、488 词条）、
/// 《日本語表現活用辞典》（UTF-16、2 个 key block、1545 词条）、
/// 《日语新明解国语辞典》（UTF-8、82 个 key block、135528 词条）。
/// 期望值（词条数、首尾词头、释义片段）由 python 参考实现
/// （readmdict.py 的 `_decode_key_block_info` 路径）在同一份文件上跑出来。
///
/// 跳过条件：文件不存在。本地开发机没有 Flutter，测试都在服务器上跑，
/// 所以夹具放在服务器 `/opt/dict_build/` 下；`/tmp` 那份是临时调试用的候选。
void main() {
  const candidates = [
    '/opt/dict_build/bunkei_enc2.mdx',
    '/tmp/dicts_dl/日语词典/日本語表現文型辞典.mdx',
  ];
  const katsuyouCandidates = [
    '/opt/dict_build/katsuyou_enc2.mdx',
    '/tmp/dicts_dl/日语词典/日本語表現活用辞典.mdx',
  ];

  File? firstExisting(List<String> paths) {
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    return null;
  }

  test('Encrypted=2 + UTF-16 + 单 key block：488 词条', () {
    final file = firstExisting(candidates);
    if (file == null) {
      print('跳过：${candidates.first} 不存在');
      return;
    }

    final reader = MdxReader.fromFile(file.path);
    expect(reader.encoding, 'UTF-16');
    expect(reader.version, 2.0);
    expect(reader.entryCount, 488, reason: '索引表解密+解压后才能读出词条数');

    final keys = <String>[];
    final defs = <String, String>{};
    for (final e in reader.entries()) {
      final k = MdxReader.cleanKey(e.key);
      keys.add(k);
      defs.putIfAbsent(k, () => MdxReader.cleanDefinition(e.value));
    }

    expect(keys.length, 488);
    expect(keys.first, '001 ＊～間に／＊～間は');
    expect(keys[1], '002 ＊～あげく（に）／～果て（に）');
    expect(keys.last, '488 終わりに当たって');

    // 释义来自记录区（zlib 块），说明索引表切分正确、偏移对得上
    expect(defs['003 ～上げる／～上がる'], isNotNull);
    expect(
      defs['003 ～上げる／～上がる']!,
      contains('他動詞：［ます］形　＋　上げる'),
    );
  });

  test('Encrypted=2 + UTF-16 + 两个 key block：1545 词条', () {
    final file = firstExisting(katsuyouCandidates);
    if (file == null) {
      print('跳过：${katsuyouCandidates.first} 不存在');
      return;
    }

    final reader = MdxReader.fromFile(file.path);
    expect(reader.encoding, 'UTF-16');
    expect(reader.version, 2.0);
    expect(reader.entryCount, 1545);

    final keys = <String>[];
    var firstDef = '';
    for (final e in reader.entries()) {
      keys.add(MdxReader.cleanKey(e.key));
      if (firstDef.isEmpty) firstDef = MdxReader.cleanDefinition(e.value);
    }

    expect(keys.length, 1545);
    expect(keys.first, 'あいする【愛する】');
    expect(keys.last, 'ルーズ【loose［英語ではルース］】');
    expect(firstDef, contains('を愛する'));
  });

  test('Encrypted=2 + UTF-8 + 82 个 key block：135528 词条', () {
    // 编码这一维必须单独盖：UTF-8 下 _decodeKeyBlockInfo 里 head/tail 尺寸按
    // 字节算，UTF-16 下要乘 2。上面两本都是 UTF-16，走的是乘 2 那条分支。
    final file = firstExisting(const [
      '/opt/dict_build/shinmeikai_enc2.mdx',
      '/tmp/dicts_dl/日语词典/日语新明解国语辞典.mdx',
    ]);
    if (file == null) {
      print('跳过：shinmeikai_enc2.mdx 不存在');
      return;
    }

    final reader = MdxReader.fromFile(file.path);
    expect(reader.encoding, 'UTF-8');
    expect(reader.version, 2.0);
    // 这条断言就是全套：key block info 要先解密才能解压，82 个 key block
    // 还要逐个解出来，总数才会对。
    expect(reader.entryCount, 135528);

    // 只取前几条：记录区有 305 个块，全跑一遍要二十多秒，而"切分对不对"
    // 看开头几条已经足够。
    final head = reader.entries().take(3).toList();
    expect(head.map((e) => MdxReader.cleanKey(e.key)).toList(), [
      '[0][1]めいくん',
      '[1]レ',
      'ABC',
    ]);
    expect(MdxReader.cleanDefinition(head[2].value), contains('アルファベット'));
  });
}
