import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/mdx_reader.dart';

/// v2.0 词典的回归夹具（662 / 705 字节）。
///
/// 为什么需要它：真机金标用的《小学馆V2》是 **MDX 1.2**，所以 v2 分支
/// 从来没在真实文件上跑过 —— 结果 v2 的 key 区头部偏移少了 4 字节
/// （v2 = 5 个 8 字节数字 + 4 字节 adler32 = 44 字节，代码只跳了 40），
/// 于是任何 v2 词典都以 `Filter error, bad data` 直接失败，而 v1.2
/// 一切正常。
///
/// 记录体末尾带 NUL 终止符（真实文件都有；writemdict / MdxBuilder 都会
/// 写），用来守住「记录分隔符不能漏进释义」—— 夹具不带终止符时，那个
/// 漏 NUL 的 bug 是看不见的。
///
/// 这两段字节由 lute-v3 的 `tests/unit/dict/mdx_fixture.py` 生成，并且
/// **已用独立实现 mdict-utils 1.3.14 读取验证通过**。这一点很关键：
/// 如果夹具是照着本解析器的假设拼的，两者会犯同一个错、互相抵消，
/// 测试照样绿。改动解析器后若重新生成，请一并更新这里。
const _v2Utf8Base64 =
    'AAABQDwAPwB4AG0AbAAgAHYAZQByAHMAaQBvAG4APQAiADEALgAwACIAIABlAG4AYwBvAGQAaQBu'
    'AGcAPQAiAFUAVABGAC0AOAAiAD8APgAKADwARABpAGMAdABpAG8AbgBhAHIAeQAgAEcAZQBuAGUA'
    'cgBhAHQAZQBkAEIAeQBFAG4AZwBpAG4AZQBWAGUAcgBzAGkAbwBuAD0AIgAyAC4AMAAiACAAUgBl'
    'AHEAdQBpAHIAZQBkAEUAbgBnAGkAbgBlAFYAZQByAHMAaQBvAG4APQAiADIALgAwACIAIABFAG4A'
    'YwByAHkAcAB0AGUAZAA9ACIATgBvACIAIABFAG4AYwBvAGQAaQBuAGcAPQAiAFUAVABGAC0AOAAi'
    'ACAAVABpAHQAbABlAD0AIgBGAGkAeAB0AHUAcgBlACIALwA+AAAAnDRrewAAAAAAAAABAAAAAAAA'
    'AAMAAAAAAAAAUAAAAAAAAABHAAAAAAAAAGQIxwEAAgAAAEiOGiF4nGNgAANmBn2bRIWMotQ0W6XU'
    'vJKiSit9/ceN8x83rnvcOP1xY4uSHTLPRj/RDqjn+bqNDFCQAqVjAEiOGiEAAAAALPojlwAAAAAA'
    'AAAAPGEgaHJlZj0iZW50cnk6Ly/jgZ/jga7jgZfjgYQiPuOBn+OBruOBl+OBhDwvYT4AAAAAAAAA'
    'ACDjgbLjgZXjgZfjgbbjgooAAAAAAAAAADjnrrEAAAAAAAAAAAEAAAAAAAAAAwAAAAAAAAAQAAAA'
    'AAAAAEcAAAAAAAAARwAAAAAAAAA/AAAAAPhnH3Q8ZGl2PualveOBl+OBhDxici8+5oSJ5b+rPC9k'
    'aXY+ADxkaXY+5LmF44GX5oyv44KKPC9kaXY+AOOBr+OBkwA=';

const _v2Utf16Base64 =
    'AAABQjwAPwB4AG0AbAAgAHYAZQByAHMAaQBvAG4APQAiADEALgAwACIAIABlAG4AYwBvAGQAaQBu'
    'AGcAPQAiAFUAVABGAC0AOAAiAD8APgAKADwARABpAGMAdABpAG8AbgBhAHIAeQAgAEcAZQBuAGUA'
    'cgBhAHQAZQBkAEIAeQBFAG4AZwBpAG4AZQBWAGUAcgBzAGkAbwBuAD0AIgAyAC4AMAAiACAAUgBl'
    'AHEAdQBpAHIAZQBkAEUAbgBnAGkAbgBlAFYAZQByAHMAaQBvAG4APQAiADIALgAwACIAIABFAG4A'
    'YwByAHkAcAB0AGUAZAA9ACIATgBvACIAIABFAG4AYwBvAGQAaQBuAGcAPQAiAFUAVABGAC0AMQA2'
    'ACIAIABUAGkAdABsAGUAPQAiAEYAaQB4AHQAdQByAGUAIgAvAD4AAADLNBngAAAAAAAAAAEAAAAA'
    'AAAAAwAAAAAAAABgAAAAAAAAAFEAAAAAAAAAcAo9ASYCAAAAkwQNbXicY2AAA2YGeRuGRAYFhgyG'
    'IoZUhjQGWwYlIJ3HUALkVzJYMegDYbxBnkG4gYuBEoMdnG0DFE8E8oGAcWM1AwwUQOkMAJMEDW0A'
    'AAAAIloP+AAAAAAAAAAAPABhACAAaAByAGUAZgA9ACIAZQBuAHQAcgB5ADoALwAvAF8wbjBXMEQw'
    'IgA+AF8wbjBXMEQwPAAvAGEAPgAAAAAAAAAAAAAscjBVMFcwdjCKMAAAAAAAAAAAAEyxewAAAAAA'
    'AAAAAAEAAAAAAAAAAwAAAAAAAAAQAAAAAAAAAFoAAAAAAAAAWgAAAAAAAABSAAAAALRED+08AGQA'
    'aQB2AD4AfWlXMEQwPABiAHIALwA+AAlh6188AC8AZABpAHYAPgAAADwAZABpAHYAPgBFTlcwL2OK'
    'MDwALwBkAGkAdgA+AAAAbzBTMAAA';

Uint8List _v2Utf8() => base64.decode(_v2Utf8Base64);

Uint8List _v2Utf16() => base64.decode(_v2Utf16Base64);

void main() {
  // 这条只是把格式契约钉在夹具上（对文件成立，与解析器无关），给后面
  // 两条和未来的改动当参照。真正守住解析器的是下面两条 parse 测试：
  // 把偏移改回 40，它们会以 `Filter error, bad data` 变红。
  test('夹具本身是 v2 布局：key block info 从 +44 起', () {
    final bytes = _v2Utf8();
    final headerLen = ByteData.sublistView(
      bytes,
      0,
      4,
    ).getUint32(0, Endian.big);
    // 文件头 = 4 字节大端长度 + header + 4 字节 adler32（v1.2 也写）。
    final keyBlockOffset = 4 + headerLen + 4;

    // key block info 的头 4 字节是块头里的压缩方式字：2 = zlib，小端。
    // 这也是 mdict-utils 自己断言的那 4 个字节 —— 从 +40 读就会读到
    // adler32 的尾巴，而不是这个字。
    expect(
      bytes.sublist(keyBlockOffset + 44, keyBlockOffset + 48),
      [2, 0, 0, 0],
      reason: 'key block info 必须从 +44 开始；从 +40 开始就是少跳了 adler32',
    );
  });

  test('解析 v2.0 + UTF-8 词典', () {
    final reader = MdxReader(_v2Utf8());

    expect(reader.version, 2.0);
    expect(reader.encoding, 'UTF-8');
    expect(reader.entryCount, 3);

    final entries = {
      for (final e in reader.entries()) MdxReader.cleanKey(e.key): e.value,
    };
    expect(entries.length, 3);
    expect(
      MdxReader.cleanDefinition(entries['たのしい']!),
      contains('楽しい'),
    );
    expect(
      MdxReader.cleanDefinition(entries['たのしい']!),
      contains('愉快'),
    );
    expect(MdxReader.cleanDefinition(entries['ひさしぶり']!), '久し振り');
    expect(MdxReader.cleanDefinition(entries['箱']!), 'はこ');
    // 记录末尾的 NUL 分隔符必须已被剥掉：它不在 strip() 的空白定义里，
    // 漏掉就会一路跟着释义进到词卡。
    expect(entries.values.every((d) => !d.contains('\u0000')), isTrue);
  });

  test('解析 v2.0 + UTF-16 词典（head/tail 长度按 16-bit 单元计）', () {
    final reader = MdxReader(_v2Utf16());

    expect(reader.version, 2.0);
    expect(reader.encoding, 'UTF-16');
    expect(reader.entryCount, 3);

    final entries = {
      for (final e in reader.entries()) MdxReader.cleanKey(e.key): e.value,
    };
    expect(entries.length, 3);
    expect(
      MdxReader.cleanDefinition(entries['たのしい']!),
      contains('楽しい'),
    );
    expect(MdxReader.cleanDefinition(entries['ひさしぶり']!), '久し振り');
    expect(MdxReader.cleanDefinition(entries['箱']!), 'はこ');
    expect(entries.values.every((d) => !d.contains('\u0000')), isTrue);
  });
}
