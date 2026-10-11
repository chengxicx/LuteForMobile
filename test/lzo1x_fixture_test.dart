import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/lzo1x.dart';

/// LZO1X 移植的逐块金标：python-lzo（真实库）解压的 87 个 MDX key block
/// 作为期望输出，我的纯 Dart 移植必须逐字节一致。fixture 在验证服务器
/// 的 /tmp/dict_fixtures/（生成脚本见对话/lute-v3 tools 注释），本地无
/// fixture 时整组跳过。
void main() {
  final manifestFile = File('/tmp/dict_fixtures/manifest.json');

  test('LZO1X：87 个真实 MDX 块逐字节一致', () {
    if (!manifestFile.existsSync()) {
      print('跳过：/tmp/dict_fixtures/manifest.json 不存在');
      return;
    }
    final manifest =
        (jsonDecode(manifestFile.readAsStringSync()) as List).cast<Map>();

    var checked = 0;
    for (final m in manifest) {
      final decSize = m['decSize'] as int;
      final comp = File('/tmp/dict_fixtures/${m['lzo']}').readAsBytesSync();
      final expected = File('/tmp/dict_fixtures/${m['out']}').readAsBytesSync();

      final out = lzo1xDecompress(
        Uint8List.fromList(comp),
        comp.length,
        decSize,
      );
      expect(
        out.length,
        decSize,
        reason: '块 ${m['i']}：解压长度不符',
      );
      for (var i = 0; i < decSize; i++) {
        if (out[i] != expected[i]) {
          fail('块 ${m['i']} 在偏移 $i 不一致：'
              'got ${out[i]} want ${expected[i]}');
        }
      }
      checked++;
    }
    expect(checked, 87);
  });
}
