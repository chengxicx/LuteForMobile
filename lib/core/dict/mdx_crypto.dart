/// MDX 词典的两种"加密"原语（移植自 mdict_utils 的 readmdict.py 与
/// zhansliu/writemdict 的 ripemd128.py，算法参考、代码重写）。
///
/// 现实中绝大多数 MDX 2.0 词典的头部都写着 `Encrypted="2"`——它**不是**
/// 密码学加密，而是把 key block info（记录块索引表）用一个**可推导**的
/// 密钥做了一遍异或混淆，密钥只依赖该块自己的 adler32：
///
/// ```
/// key = ripemd128(block[4:8] + <L 0x3695>)
/// plain = fastDecrypt(block[8:], key)
/// ```
///
/// 所以不需要任何用户密码就能解开。真正的密码学加密只有 `Encrypted=1`
/// （需要 MdxBuilder 生成词典时给的 regcode），本解析器不支持。
library;

import 'dart:typed_data';

/// 32 位循环左移。
int _rol(int s, int x) => ((x << s) | (x >>> (32 - s))) & 0xffffffff;

/// 32 位无符号相加（Dart 的 int 是 64 位，必须显式截断）。
int _add(List<int> args) {
  var sum = 0;
  for (final a in args) {
    sum = (sum + a) & 0xffffffff;
  }
  return sum;
}

/// RIPEMD-128：MDX 用它把 adler32 摊成一个 16 字节密钥。
///
/// 这就是 `_decodeBlock` 里 `encrypted_key = ripemd128(block[4:8])` 那一步。
Uint8List ripemd128(List<int> message) {
  const r = <int>[
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8, //
    3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12, //
    1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2, //
  ];
  const rp = <int>[
    5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, //
    6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2, //
    15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13, //
    8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14, //
  ];
  const s = <int>[
    11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, //
    7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12, //
    11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, //
    11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12, //
  ];
  const sp = <int>[
    8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, //
    9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11, //
    9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, //
    15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8, //
  ];

  int f(int j, int x, int y, int z) {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | (z & (~x & 0xffffffff));
    if (j < 48) return (x | (~y & 0xffffffff)) ^ z;
    return (x & z) | (y & (~z & 0xffffffff));
  }

  int k(int j) {
    if (j < 16) return 0x00000000;
    if (j < 32) return 0x5a827999;
    if (j < 48) return 0x6ed9eba1;
    return 0x8f1bbcdc;
  }

  int kp(int j) {
    if (j < 16) return 0x50a28be6;
    if (j < 32) return 0x5c4dd124;
    if (j < 48) return 0x6d703ef3;
    return 0x00000000;
  }

  // pad：补 0x80 + 若干 0x00，使长度 ≡ 56 (mod 64)，再补 8 字节小端位长。
  // 注意 padLength 的最小值是 1（原长恰好 ≡56 时也要补满一整块）。
  final origLen = message.length;
  final padLength = 64 - ((origLen - 56) % 64);
  final padded = Uint8List(origLen + padLength + 8);
  padded.setRange(0, origLen, message);
  padded[origLen] = 0x80;
  final bitLen = origLen * 8;
  for (var i = 0; i < 8; i++) {
    padded[padded.length - 8 + i] = (bitLen >>> (8 * i)) & 0xff;
  }

  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;

  final x = List<int>.filled(16, 0);
  for (var base = 0; base < padded.length; base += 64) {
    for (var j = 0; j < 16; j++) {
      final o = base + j * 4;
      x[j] = padded[o] |
          (padded[o + 1] << 8) |
          (padded[o + 2] << 16) |
          (padded[o + 3] << 24);
    }
    var a = h0, b = h1, c = h2, d = h3;
    var ap = h0, bp = h1, cp = h2, dp = h3;
    for (var j = 0; j < 64; j++) {
      var t = _rol(s[j], _add([a, f(j, b, c, d), x[r[j]], k(j)]));
      a = d;
      d = c;
      c = b;
      b = t;
      t = _rol(sp[j], _add([ap, f(63 - j, bp, cp, dp), x[rp[j]], kp(j)]));
      ap = dp;
      dp = cp;
      cp = bp;
      bp = t;
    }
    final t = _add([h1, c, dp]);
    h1 = _add([h2, d, ap]);
    h2 = _add([h3, a, bp]);
    h3 = _add([h0, b, cp]);
    h0 = t;
  }

  final out = Uint8List(16);
  final words = [h0, h1, h2, h3];
  for (var i = 0; i < 4; i++) {
    out[i * 4] = words[i] & 0xff;
    out[i * 4 + 1] = (words[i] >>> 8) & 0xff;
    out[i * 4 + 2] = (words[i] >>> 16) & 0xff;
    out[i * 4 + 3] = (words[i] >>> 24) & 0xff;
  }
  return out;
}

/// MDX 的异或混淆（readmdict 的 `_fast_decrypt`）。
///
/// 每一字节先高低半字节互换，再依次异或：上一字节原文（首字节用 0x36）、
/// 字节下标低 8 位、密钥循环。加密解密是同一个函数。
///
/// ⚠️ `previous` 必须取**密文**（即入参的原始字节），不是刚算出的结果——
/// 写成 `previous = t` 会得到一个看似正常、解出的 zlib 却永远坏掉的流。
Uint8List fastDecrypt(List<int> data, List<int> key) {
  final b = Uint8List.fromList(data);
  var previous = 0x36;
  for (var i = 0; i < b.length; i++) {
    final original = b[i];
    var t = ((original >> 4) | (original << 4)) & 0xff;
    t = t ^ previous ^ (i & 0xff) ^ key[i % key.length];
    previous = original;
    b[i] = t;
  }
  return b;
}

/// `Encrypted=2` 时 key block info 用的密钥：只由该块的 adler32 决定。
///
/// 对应 readmdict 的
/// `ripemd128(block[4:8] + pack('<L', 0x3695))`——注意 `<L` 是小端，
/// 0x3695 摊成 4 字节就是 `95 36 00 00`。这里的 [adler32Bytes] 是块里
/// 原样的 4 个字节（大端序，但推导密钥时只当字节串用，不解析成整数）。
Uint8List encryptedKeyBlockInfoKey(List<int> adler32Bytes) {
  final seed = Uint8List(8);
  seed.setRange(0, 4, adler32Bytes);
  seed[4] = 0x95; // 0x3695 小端
  seed[5] = 0x36;
  seed[6] = 0x00;
  seed[7] = 0x00;
  return ripemd128(seed);
}

/// `_decodeBlock` 在没有用户密钥时用的块密钥：只由块的 adler32 决定。
Uint8List blockKeyFromAdler32(List<int> adler32Bytes) => ripemd128(adler32Bytes);
