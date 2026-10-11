import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/mdx_crypto.dart';

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // 期望值全部由 python 参考实现（zhansliu/writemdict 的 ripemd128.py +
  // readmdict.py 的 _fast_decrypt）在同一台机器上生成，逐字节比对。
  group('ripemd128', () {
    const vectors = <String, String>{
      '': 'cdf26213a150dc3ecb610f18f6b38b46',
      'a': '86be7afa339d0fc7cfc785e72f578d33',
      'abc': 'c14a12199c66e4ba84636b0f69144c77',
      'The quick brown fox jumps over the lazy dog':
          '3fa9b57f053c053fbe2735b2380db596',
    };

    vectors.forEach((input, expected) {
      test('ripemd128(${jsonEncode(input)})', () {
        expect(
          bytesToHex(ripemd128(utf8.encode(input))),
          expected,
        );
      });
    });

    // 补位边界：padlength = 64 - ((len - 56) % 64)，len%64 == 56 时要补满
    // 一整块（1 + 63 + 8），写成 `% 64` 而漏掉最小值 1 就会少一块。
    const paddingVectors = <int, String>{
      55: '939ea8b9c8a62aa6c18f47b65743dce8',
      56: '01b3ed3753c897abadee8a09b85760a6',
      57: '3e5ae162a76b051b3632c1cb36885833',
      64: '0411681595c303a45bdc9eeefb73b666',
      119: '5e5c68d0bb2013fd6ac35c3c355eca7b',
      120: '1dd177f75f676c848cff0e6d7d970dbf',
    };

    paddingVectors.forEach((len, expected) {
      test('ripemd128($len 个 x)：补位边界', () {
        expect(bytesToHex(ripemd128(List.filled(len, 0x78))), expected);
      });
    });

    test('ripemd128(0..255)：多块 + 高位字节', () {
      expect(
        bytesToHex(ripemd128(List.generate(256, (i) => i))),
        'afca668bb766607f8081c2126ad9fd5c',
      );
    });

    test('单字节输入：~x 必须截断到 32 位', () {
      // Dart 的 int 是 64 位，`~x` 对短输入会给出负的 64 位数；不按
      // 0xffffffff 截断的话结果会带上高位垃圾。
      expect(bytesToHex(ripemd128([0x00])), 'f069a435c14a8d4b02a7bbaee02d0bc3');
      expect(bytesToHex(ripemd128([0xff])), '8e5fbc60bf2883c93113e8105839ea17');
      expect(bytesToHex(ripemd128([0x80])), '05957327445b2f6e42917f2e805f011c');
      expect(bytesToHex(ripemd128([0x00, 0xff])), '04e8277030772a06d076cbc6075ecc45');
    });
  });

  group('fastDecrypt', () {
    test('200 字节异或流（逐字节对 python）', () {
      const inputHex =
          '030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff'
          '060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb'
          '020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe'
          '050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01'
          '080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd04'
          '0b121920272e353c434a51585f666d74';
      const expectedHex =
          '06b33ba0a92d941e078f76fce562e8534bd4522920a63fb78e0099156ceb63f8c27df56e'
          '67ef961c058930baa324aa5149d65ce7ee68f1758c029b132aad25bec03fb72c25a11892'
          '8b0b72f8e166ec574fd05ea5ac2ab33b028c159168ef67fcc679f16a63e31a908905bc36'
          '2fa82e554dd258e3ea6cf579008e179fa621a932c4bb33a8a1259c160f877ef4ed6ae05b'
          '43dc5a2128ae37bf8608911d64e36bf0ca75fd666fe79e140d8138b2ab2ca25941de54efe'
          '660f97d840a931b22a52db6c837bf242da9109a';
      final out = fastDecrypt(
        hexToBytes(inputHex),
        hexToBytes('00112233445566778899aabbccddeeff'),
      );
      expect(bytesToHex(out), expectedHex);
    });

    test('不是对合函数：连解两次不会回到原文', () {
      // 容易踩的坑：以为 fast_decrypt 是"加密解密同一个函数、做两遍还原"。
      // 不是。每字节异或的 `previous` 取的是**当前这一步的输入**，而
      // nibble 互换又是 GF(2) 线性的，所以第二遍拿到的 previous 不同，
      // 结果既不是原文、也不是密文。写代码时别把它当可逆变换用。
      const dataHex =
          '0714212e3b4855626f7c8996a3b0bdcad7e4f1fe0b1825323f4c596673808d9a';
      const onceHex =
          '75fde3c71baa62ce82e7cbf27d4c88e594320e0ad88f25abc7a4e63d908fabc0';
      const twiceHex =
          '5211269bf0a4f333f0b374f6f45d27228f1c27ba1125b232d1d2f537f59cc643';
      final key = hexToBytes('33bae707821079ba1e462519dde9edfb');

      final once = fastDecrypt(hexToBytes(dataHex), key);
      expect(bytesToHex(once), onceHex);
      final twice = fastDecrypt(once, key);
      expect(bytesToHex(twice), twiceHex);
      expect(bytesToHex(twice), isNot(dataHex));
    });

    test('previous 取密文：用明文当 previous 会解错', () {
      final data = hexToBytes('030a11181f262d343b424950575e65');
      final key = hexToBytes('00112233445566778899aabbccddeeff');
      final out = fastDecrypt(data, key);
      // 手算第 0 字节：(0x03 半字节互换 = 0x30) ^ 0x36 ^ 0x00 ^ 0x00 = 0x06
      expect(out[0], 0x06);
      // 手算第 1 字节：(0x0a -> 0xa0) ^ 0x03(上一字节密文) ^ 0x01 ^ 0x11 = 0xb3
      expect(out[1], 0xb3);
    });
  });

  group('Encrypted=2 的 key block info（真实词典夹具）', () {
    // 取自 mdict.org 的《日本語表現文型辞典》——一本 Encrypted=2 的
    // MDX 2.0（UTF-16、zlib）。这是该文件里那段 75 字节的 key block info
    // 原文，逐字节来自真实文件，不是构造出来的。
    const infoHex =
        '0200000014271330d76bdeabd26c5d7f5652b79ad4c36a29651350ab27cbe3324ffeedd29d'
        'e561fcc99c96ae8041d442bc291b861c99a2a0f1b34d83faed1a386dda74688a121ccc891638';
    const keyHex = '33bae707821079ba1e462519dde9edfb';
    const decryptedHex =
        '78da63600001c6170c3c060c060c860c5cffe3fe4f9e9a6dc0ff1fc2ca37004a739b3058'
        '00a1536dbf419741b641707cbc41b2419a010314c8bf82d0217f0014271330';
    // zlib 解开后：1 个 key block、488 词条、索引表 78 字节
    const plainHex =
        '00000000000001e8000c3000300031000aff5eff93956b300fff0aff5eff93956f30000000'
        '0b340038003800427d8f308a306b30535f5f306330663000000000000000001fea00000000'
        '000054fc';

    test('密钥推导 + 异或解密 + zlib，逐字节对上 python', () {
      final info = hexToBytes(infoHex);
      expect(info.length, 75);

      // 前 8 字节（02 00 00 00 + adler32）不参与混淆
      expect(info.sublist(0, 4), [2, 0, 0, 0]);

      final key = encryptedKeyBlockInfoKey(info.sublist(4, 8));
      expect(bytesToHex(key), keyHex, reason: '密钥只由 adler32 推出');

      final payload = fastDecrypt(info.sublist(8), key);
      expect(bytesToHex(payload), decryptedHex);

      final plain = Uint8List.fromList(ZLibDecoder().convert(payload));
      expect(plain.length, 78, reason: '与头部声明的 key block info 解压长度一致');
      expect(bytesToHex(plain), plainHex);
    });

    test('索引表能解出 1 个块、488 词条', () {
      final plain = Uint8List.fromList(
        ZLibDecoder().convert(
          fastDecrypt(
            hexToBytes(infoHex).sublist(8),
            encryptedKeyBlockInfoKey(hexToBytes(infoHex).sublist(4, 8)),
          ),
        ),
      );
      // 第 1 个 8 字节数字 = 该 key block 的词条数
      var entries = 0;
      for (var i = 0; i < 8; i++) {
        entries = (entries << 8) | plain[i];
      }
      expect(entries, 488);
    });
  });
}
