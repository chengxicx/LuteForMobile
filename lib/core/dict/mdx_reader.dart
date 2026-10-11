import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lzo1x.dart';

/// 纯 Dart 的 MDX 词典解析器（移植自 mdict_utils 的 readmdict.py，GPL 部分
/// 算法参考、代码重写）。支持：MDX v1.2 / v2.0 / v3.0，Encoding = UTF-8 或
/// UTF-16，块压缩 = 无 / zlib / LZO1X。**不支持加密词典**（Encrypted=1/2、
/// 带 regcode/UUID 的密钥加密）——mdict.org 的免费词典绝大多数不加密。
///
/// 用法：`MdxReader(path)` 打开文件，`entries()` 流式产出（key, 定义原文）。
/// key 与定义都可能是 MDX 内部的 HTML 片段（key 常带链接包装），展示前
/// 由调用方剥标签。
class MdxReader {
  MdxReader(this._bytes) {
    _readHeader();
  }

  factory MdxReader.fromFile(String path) => MdxReader(File(path).readAsBytesSync());

  final Uint8List _bytes;

  late final double version;
  late final String encoding;
  int _numberWidth = 8;
  bool _utf16 = false;
  int _encrypt = 0;
  late int _keyBlockOffset;

  String _title = '';
  String get title => _title;

  // —— 基础读取 ——
  int _be(Uint8List b, int offset, int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 8) | b[offset + i];
    }
    return v;
  }

  int _le32(Uint8List b, int offset) =>
      b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16) | (b[offset + 3] << 24);

  Uint8List _zlibDecode(Uint8List data) {
    final decoder = ZLibDecoder();
    return Uint8List.fromList(decoder.convert(data));
  }

  Uint8List _decodeBlock(Uint8List block, int decompressedSize) {
    final info = _le32(block, 0);
    final compression = info & 0xf;
    final encryption = (info >> 4) & 0xf;
    if (encryption != 0) {
      throw const FormatException('MDX: 加密词典暂不支持（Encrypted）');
    }
    final data = Uint8List.sublistView(block, 8);
    switch (compression) {
      case 0:
        return data;
      case 1:
        return lzo1xDecompress(data, data.length, decompressedSize);
      case 2:
        return _zlibDecode(data);
      default:
        throw FormatException('MDX: 未知压缩方式 $compression');
    }
  }

  // —— Header ——
  void _readHeader() {
    final headerLen = _be(_bytes, 0, 4);
    var headerBytes = Uint8List.sublistView(_bytes, 4, 4 + headerLen);
    // 头部 XML 后固定 4 字节 adler32（v1.2 和 v2.0 都写，见
    // writemdict._write_header 末尾那条无条件的 b"<L"）；这里不校验，
    // 宽容解析。少跳这 4 字节会让后面每个偏移都错位。
    _keyBlockOffset = 4 + headerLen + 4;

    // UTF-16LE 文本，以 \x00\x00 结尾
    Uint8List textBytes = headerBytes;
    if (headerBytes.length >= 2 &&
        headerBytes[headerBytes.length - 2] == 0 &&
        headerBytes[headerBytes.length - 1] == 0) {
      textBytes = Uint8List.sublistView(headerBytes, 0, headerBytes.length - 2);
    }
    final units = <int>[];
    for (var i = 0; i + 1 < textBytes.length; i += 2) {
      units.add(textBytes[i] | (textBytes[i + 1] << 8));
    }
    final headerText = String.fromCharCodes(units);

    final tags = <String, String>{};
    final regex = RegExp('([A-Za-z0-9_]+)="([^"]*)"', dotAll: true);
    for (final m in regex.allMatches(headerText)) {
      tags[m.group(1)!] = (m.group(2) ?? '')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&');
    }
    _title = tags['Title'] ?? '';

    encoding = (tags['Encoding'] ?? 'utf-8').toUpperCase();
    if (encoding == 'GBK' || encoding == 'GB2312') encoding = 'GB18030';
    if (encoding != 'UTF-8' && encoding != 'UTF-16' && encoding != 'UTF-16LE') {
      throw FormatException('MDX: 暂不支持编码 $encoding（仅 UTF-8 / UTF-16）');
    }
    _utf16 = encoding.startsWith('UTF-16');

    final encrypted = tags['Encrypted'] ?? 'No';
    _encrypt = encrypted == 'No' ? 0 : int.tryParse(encrypted) ?? 0;
    if (_encrypt != 0) {
      throw FormatException('MDX: 加密词典暂不支持（Encrypted=$_encrypt）');
    }

    version = double.parse(tags['GeneratedByEngineVersion'] ?? '2.0');
    if (version >= 3) {
      encoding = 'UTF-8';
      _utf16 = false;
    }
    _numberWidth = version < 2 ? 4 : 8;
  }

  // —— Keys ——
  List<MapEntry<int, String>>? _keyList;

  /// 记录区在文件中的起始偏移（keys 解析后即知）。
  int get recordBlockOffset => _recordBlockOffset;

  void _ensureKeys() {
    if (_keyList == null) _readKeys();
  }
  late int _recordBlockOffset;

  void _readKeys() {
    if (version >= 3) {
      _readKeysV3();
    } else {
      _readKeysV1V2();
    }
  }

  late int _numEntries;
  int get entryCount {
    _ensureKeys();
    return _numEntries;
  }

  int _readNumber(Uint8List b, int offset) => _be(b, offset, _numberWidth);

  List<(int, int)> _decodeKeyBlockInfo(Uint8List info, {int expectedSize = 0}) {
    final list = <(int, int)>[];
    if (version >= 2) {
      // zlib 压缩；首 4 字节 02 00 00 00，再 4 字节 adler，再 zlib 数据
      final decompressed = _zlibDecode(Uint8List.sublistView(info, 8));
      // 解压长度必须等于 key 区头部声明的值。这条断言正是冲着"少跳
      // 4 字节"那类偏移错误来的：偏移错了这里立刻炸，而不是等到记录区
      // 切分时才出现莫名其妙的结果。
      assert(
        expectedSize == 0 || decompressed.length == expectedSize,
        'key block info 解压后 ${decompressed.length} 字节，'
        '头部声明 $expectedSize 字节（key 区偏移可能错了）',
      );
      const byteWidth = 2;
      final textTerm = 1;
      var i = 0;
      while (i < decompressed.length) {
        i += _numberWidth; // 该块词条数（跳过，最后用 key_list 实数）
        final headSize = _be(decompressed, i, byteWidth);
        i += byteWidth + (headSize + textTerm) * (_utf16 ? 2 : 1);
        final tailSize = _be(decompressed, i, byteWidth);
        i += byteWidth + (tailSize + textTerm) * (_utf16 ? 2 : 1);
        final compSize = _readNumber(decompressed, i);
        i += _numberWidth;
        final decompSize = _readNumber(decompressed, i);
        i += _numberWidth;
        list.add((compSize, decompSize));
      }
    } else {
      const byteWidth = 1;
      const textTerm = 0;
      var i = 0;
      while (i < info.length) {
        i += _numberWidth;
        final headSize = _be(info, i, byteWidth);
        // v1 的 head/tail 尺寸按字符数存储，UTF-16 下要乘 2 才是字节数
        //（实测小学馆V2：87 块 info 总长 3776，不乘 2 会走出界）。
        i += byteWidth + (headSize + textTerm) * (_utf16 ? 2 : 1);
        final tailSize = _be(info, i, byteWidth);
        i += byteWidth + (tailSize + textTerm) * (_utf16 ? 2 : 1);
        final compSize = _readNumber(info, i);
        i += _numberWidth;
        final decompSize = _readNumber(info, i);
        i += _numberWidth;
        list.add((compSize, decompSize));
      }
    }
    return list;
  }

  List<MapEntry<int, String>> _splitKeyBlock(Uint8List block) {
    final list = <MapEntry<int, String>>[];
    var start = 0;
    final width = _utf16 ? 2 : 1;
    while (start < block.length) {
      final keyId = _readNumber(block, start);
      var i = start + _numberWidth;
      while (i + width <= block.length) {
        if (width == 1
            ? block[i] == 0
            : block[i] == 0 && block[i + 1] == 0) {
          break;
        }
        i += width;
      }
      final textBytes = Uint8List.sublistView(block, start + _numberWidth, i);
      final text = _utf16
          ? String.fromCharCodes([
              for (var j = 0; j + 1 < textBytes.length; j += 2)
                textBytes[j] | (textBytes[j + 1] << 8),
            ])
          : utf8.decode(textBytes, allowMalformed: true);
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        list.add(MapEntry(keyId, trimmed));
      }
      start = i + width;
    }
    return list;
  }

  void _readKeysV1V2() {
    var offset = _keyBlockOffset;
    // key 区头部：v2.0 是 5 个 8 字节大端数字 **再加 4 字节 adler32**
    // （共 44 字节），v1.2 是 4 个 4 字节数字、无校验和（共 16 字节）。
    // 见 writemdict._write_key_sect：v2 先写 b">QQQQQ"，再写
    // b">L" 的 zlib.adler32(preamble)。
    //
    // 校验和必须和数字一起跳过。少跳这 4 字节，key block info 就会从
    // adler32 的第 1 个字节开始读，_decodeKeyBlockInfo 里跳掉的 8 字节
    // 前缀对不上，zlib 直接抛 "incorrect header check" —— 报错位置离
    // 真正的偏移错误很远，别被带偏。
    final numBytes = version >= 2 ? 8 * 5 + 4 : 4 * 4;
    final block = Uint8List.sublistView(_bytes, offset, offset + numBytes);
    if (_encrypt & 1 != 0) {
      throw const FormatException('MDX: 加密词典暂不支持');
    }

    var pos = 0;
    final numKeyBlocks = _readNumber(block, pos);
    pos += _numberWidth;
    _numEntries = _readNumber(block, pos);
    pos += _numberWidth;
    var keyBlockInfoDecompSize = 0;
    if (version >= 2) {
      keyBlockInfoDecompSize = _readNumber(block, pos);
      pos += _numberWidth;
    }
    final keyBlockInfoSize = _readNumber(block, pos);
    pos += _numberWidth;
    final keyBlockSize = _readNumber(block, pos);
    pos += _numberWidth;
    // 尾部 4 字节校验和已含在 numBytes 内，不参与解析。

    offset += numBytes;
    final keyBlockInfo = Uint8List.sublistView(
      _bytes,
      offset,
      offset + keyBlockInfoSize,
    );
    offset += keyBlockInfoSize;
    // v2 的 key block info 本身 zlib 压缩，解压后长度应等于声明值。
    final infoList = _decodeKeyBlockInfo(
      keyBlockInfo,
      expectedSize: keyBlockInfoDecompSize,
    );

    final keyBlockCompressed = Uint8List.sublistView(
      _bytes,
      offset,
      offset + keyBlockSize,
    );
    offset += keyBlockSize;
    _recordBlockOffset = offset;

    _keyList = _decodeKeyBlock(keyBlockCompressed, infoList);
    assert(numKeyBlocks == infoList.length);
  }

  List<MapEntry<int, String>> _decodeKeyBlock(
    Uint8List compressed,
    List<(int, int)> infoList,
  ) {
    final keyList = <MapEntry<int, String>>[];
    var i = 0;
    for (final (compSize, decompSize) in infoList) {
      final block = Uint8List.sublistView(compressed, i, i + compSize);
      keyList.addAll(_splitKeyBlock(_decodeBlock(block, decompSize)));
      i += compSize;
    }
    return keyList;
  }

  // v3：文件是一串 [type(int32) + size(number) + data] 的块序列。
  void _readKeysV3() {
    var offset = _keyBlockOffset;
    int? keyDataOffset;
    while (true) {
      final blockType = _be(_bytes, offset, 4);
      offset += 4;
      final blockSize = _readNumber(_bytes, offset);
      offset += _numberWidth;
      if (blockType == 0x03000000) {
        keyDataOffset = offset;
      }
      offset += blockSize;
      if (offset + 4 > _bytes.length) break;
    }
    if (keyDataOffset == null) {
      throw const FormatException('MDX: v3 缺少 key data 块');
    }

    var pos = keyDataOffset;
    final number = _be(_bytes, pos, 4);
    pos += 4;
    pos += _numberWidth; // total size
    final keyList = <MapEntry<int, String>>[];
    for (var i = 0; i < number; i++) {
      final decompSize = _be(_bytes, pos, 4);
      pos += 4;
      final compSize = _be(_bytes, pos, 4);
      pos += 4;
      final block = Uint8List.sublistView(_bytes, pos, pos + compSize);
      pos += compSize;
      keyList.addAll(_splitKeyBlock(_decodeBlock(block, decompSize)));
    }
    _numEntries = keyList.length;
    _keyList = keyList;
  }

  // —— Records ——
  /// 流式产出词条（key 已剥 HTML/空白；定义保留原始 HTML，由调用方处理）。
  Iterable<MapEntry<String, String>> entries() sync* {
    _ensureKeys();
    final keyList = _keyList!;

    var offset = 0;
    var keyIndex = 0;
    if (version >= 3) {
      // v3 的记录区同样走块扫描：从 record 区起点（key data 之后继续扫）
      throw const FormatException('MDX: v3 记录区暂不支持');
    }

    var pos = _recordBlockOffset;
    final numRecordBlocks = _readNumber(_bytes, pos);
    pos += _numberWidth;
    pos += _numberWidth; // num entries（应等于 key 数）
    final recordBlockInfoSize = _readNumber(_bytes, pos);
    pos += _numberWidth;
    pos += _numberWidth; // record block 总大小

    // record block info：每块 (compSize, decompSize)
    final info = <(int, int)>[];
    var sizeCounter = 0;
    for (var i = 0; i < numRecordBlocks; i++) {
      final compSize = _readNumber(_bytes, pos);
      pos += _numberWidth;
      final decompSize = _readNumber(_bytes, pos);
      pos += _numberWidth;
      info.add((compSize, decompSize));
      sizeCounter += _numberWidth * 2;
    }
    assert(sizeCounter == recordBlockInfoSize);

    for (final (compSize, decompSize) in info) {
      final block = _decodeBlock(
        Uint8List.sublistView(_bytes, pos, pos + compSize),
        decompSize,
      );
      pos += compSize;

      while (keyIndex < keyList.length) {
        final recordStart = keyList[keyIndex].key;
        if (recordStart - offset >= block.length) break;
        final recordEnd = keyIndex + 1 < keyList.length
            ? keyList[keyIndex + 1].key
            : block.length + offset;
        keyIndex++;
        final textBytes = Uint8List.sublistView(
          block,
          recordStart - offset,
          recordEnd - offset,
        );
        var definition = _utf16
            ? String.fromCharCodes([
                for (var j = 0; j + 1 < textBytes.length; j += 2)
                  textBytes[j] | (textBytes[j + 1] << 8),
              ])
            : utf8.decode(textBytes, allowMalformed: true);
        // 切片一路切到下一条记录的开头，会把终止本条的 NUL 分隔符一起吞进来
        // —— 真实文件每条记录都以 NUL 结尾（writemdict / MdxBuilder 都会写），
        // key 侧的 _splitKeyBlock 是显式跳过它的。Dart 的 trim() 不去 \u0000，
        // 留着就会跟着释义一路进到词卡。mdict-utils 在 MDX._treat_record_data
        // 里做同样的剥离（.strip('\x00')）。
        definition = definition.replaceAll(RegExp(r'^\u0000+|\u0000+$'), '');
        yield MapEntry(keyList[keyIndex - 1].value, definition);
      }
      offset += block.length;
    }
  }

  /// 剥掉 key 里的 HTML 包装与实体，得到纯文本词头。
  static String cleanKey(String key) {
    var k = key.replaceAll(RegExp(r'<[^>]+>'), '');
    k = k
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&');
    return k.trim();
  }

  /// 释义 HTML 转纯文本（换行保留、标签剥离、实体还原、截断）。
  static String cleanDefinition(String htmlText, {int maxChars = 800}) {
    var d = htmlText.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    d = d.replaceAll(
      RegExp(r'</(p|div|li|tr|h[1-6])>', caseSensitive: false),
      '\n',
    );
    d = d.replaceAll(RegExp(r'<[^>]+>'), '');
    d = d
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    final lines = d
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    final text = lines.join('\n');
    return text.length > maxChars ? text.substring(0, maxChars) : text;
  }
}
