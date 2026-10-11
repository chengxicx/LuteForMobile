import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/mdx_reader.dart';

/// 解析器对"坏输入"的分类：**不支持**（文件没问题，是解析器的能力边界）
/// 与**损坏**（文件本身有问题）必须分开——导入失败时前者能告诉用户
/// "换一本词典"，后者只能告诉用户"这个文件坏了"。UI 直接把 message
/// 透出来，所以措辞也在断言范围内。
///
/// 这里全部用内存里现造的小文件，不依赖任何词典夹具。
List<int> _be32(int v) => [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

/// 造一个"头部看起来像 MDX"的文件：4 字节大端头长 + UTF-16LE 的 XML +
/// 2 字节结束符 + 4 字节 adler32 占位。后面的 key/record 区故意不写——
/// 本组测试只关心头部判定。
List<int> _fakeMdx(String attrs) {
  final xml = '<?xml version="1.0" encoding="UTF-8"?><Dictionary $attrs/>';
  final body = <int>[];
  for (final c in xml.codeUnits) {
    body.add(c & 0xff);
    body.add((c >> 8) & 0xff);
  }
  body.addAll([0, 0]);
  return [..._be32(body.length), ...body, 0, 0, 0, 0];
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mdx_err'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) {
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync(bytes);
    return f;
  }

  MdxReader open(List<int> bytes) => MdxReader.fromFile(write('t.mdx', bytes).path);

  group('不是 MDX：报"损坏"', () {
    test('随机字节', () {
      final bytes = Uint8List.fromList(List.generate(512, (i) => (i * 37) & 0xff));
      expect(
        () => open(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            anyOf(contains('不是 MDX'), contains('头部')),
          ),
        ),
      );
    });

    test('JPEG 头：头长字段会解出天文数字，不能变成 RangeError', () {
      // JPEG 以 FF D8 FF E0 开头，前 4 字节当大端整数 ≈ 4.29e9。
      final bytes = Uint8List.fromList([
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46,
        ...List.filled(504, 0),
      ]);
      expect(
        () => open(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('超出文件大小'),
          ),
        ),
      );
    });

    test('太小的文件', () {
      expect(
        () => open([0x00, 0x01, 0x02]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('过小'),
          ),
        ),
      );
    });

    test('头部有内容但没有 <Dictionary> 标签', () {
      final xml = '<?xml version="1.0"?><NotADict a="b"/>';
      final body = <int>[];
      for (final c in xml.codeUnits) {
        body.add(c & 0xff);
        body.add((c >> 8) & 0xff);
      }
      body.addAll([0, 0]);
      expect(
        () => open([..._be32(body.length), ...body, 0, 0, 0, 0]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('<Dictionary>'),
          ),
        ),
      );
    });

    test('真实 MDX 被截断：抛异常而不是悄悄给半本', () {
      final fixture = File('/opt/dict_build/bunkei_enc2.mdx');
      if (!fixture.existsSync()) {
        print('跳过：夹具不存在');
        return;
      }
      final all = fixture.readAsBytesSync();
      final cut = Uint8List.sublistView(all, 0, all.length ~/ 2);
      final reader = MdxReader.fromFile(write('cut.mdx', cut).path);
      expect(
        () {
          var n = 0;
          for (final _ in reader.entries()) {
            n++;
          }
          return n;
        },
        throwsA(anyOf(isA<FormatException>(), isA<RangeError>())),
      );
    });
  });

  group('是 MDX 但超出能力边界：报"不支持"', () {
    test('Encrypted=1（regcode 加密）', () {
      expect(
        () => open(_fakeMdx(
          'GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" '
          'Encrypted="1" Encoding="UTF-8"',
        )),
        throwsA(
          isA<MdxUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('regcode'), contains('Encrypted=1')),
          ),
        ),
      );
    });

    test('Encrypted="Yes" 与 Encrypted="1" 等价', () {
      expect(
        () => open(_fakeMdx(
          'GeneratedByEngineVersion="2.0" Encrypted="Yes" Encoding="UTF-8"',
        )),
        throwsA(isA<MdxUnsupportedException>()),
      );
    });

    test('GBK 编码', () {
      expect(
        () => open(_fakeMdx(
          'GeneratedByEngineVersion="2.0" Encrypted="No" Encoding="GBK"',
        )),
        throwsA(
          isA<MdxUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('GB18030'), contains('暂不支持编码')),
          ),
        ),
      );
    });

    test('MdxUnsupportedException 也是 FormatException（旧的捕获点不会漏）', () {
      expect(
        const MdxUnsupportedException('x'),
        isA<FormatException>(),
      );
    });
  });

  group('Encrypted=2 不该被拒', () {
    test('头部通过，报错发生在后面的 key 区（因为假文件没写 key 区）', () {
      // 关键点：Encrypted="2" 不能像以前那样在头部就抛"加密词典暂不支持"。
      // 这里头长/标签都合法，只是没写 key 区，所以异常来自后面的读取，
      // 而不是"Encrypted"判定。
      Object? thrown;
      try {
        open(_fakeMdx(
          'GeneratedByEngineVersion="2.0" Encrypted="2" Encoding="UTF-8"',
        )).entryCount;
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNotNull, reason: '假文件没有 key 区，应该抛错');
      expect(
        thrown.toString(),
        isNot(contains('regcode')),
        reason: 'Encrypted=2 是可解析的，不该走"需要密钥"那条路',
      );
    });
  });
}
