import 'dart:typed_data';

/// 纯 Dart 的 LZO1X 解压（移植自 Linux 内核 lib/lzo/lzo1x_decompress_safe.c，
/// 去掉了内核特有的 bitstream-version 前缀与零串特判——MDX 里的 LZO 块是
/// 标准 lzo1x 输出）。
///
/// python-lzo 的调用约定是"5 字节合成头（0xf0 + BE32 原始长度）+ 压缩数据"，
/// C 层剥头后调 lzo1x_decompress；本函数直接接受剥头后的 [compressed]，
/// [decompressedSize] 由 MDX 块信息给出，与 python-lzo 的用法等价。
Uint8List lzo1xDecompress(
  Uint8List compressed,
  int compressedLength,
  int decompressedSize,
) {
  final input = compressed;
  final ipEnd = compressedLength;
  final out = Uint8List(decompressedSize);
  var ip = 0;
  var op = 0;
  var state = 0;

  void needIp(int n) {
    if (ip + n > ipEnd) {
      throw const FormatException('LZO: input overrun');
    }
  }

  void needOp(int n) {
    if (op + n > decompressedSize) {
      throw const FormatException('LZO: output overrun');
    }
  }

  void copyLiteral(int t) {
    needIp(t);
    needOp(t);
    while (t-- > 0) {
      out[op++] = input[ip++];
    }
  }

  void copyMatch(int t, int mPos) {
    needOp(t);
    // LZO 允许重叠拷贝（长度 2/3 的近距匹配），必须逐字节。
    for (var i = 0; i < t; i++) {
      out[op++] = out[mPos + i];
    }
  }

  void matchNext(int next) {
    state = next;
    needIp(next);
    var n = next;
    while (n-- > 0) {
      out[op++] = input[ip++];
    }
  }

  if (ipEnd < 3) throw const FormatException('LZO: input too short');

  var first = true;
  var eof = false;
  while (!eof) {
    var t = 0;
    if (first) {
      first = false;
      final t0 = input[ip];
      if (t0 > 17) {
        ip++;
        final lit = t0 - 17;
        if (lit < 4) {
          // 内核 goto match_next：拷 lit 个字面量后继续主循环
          matchNext(lit);
          continue;
        }
        copyLiteral(lit);
        state = 4;
        continue;
      }
      // 首字节 ≤ 17：不前推，当作普通控制字节进主循环
      t = t0;
    } else {
      if (ip >= ipEnd) break;
      t = input[ip++];
    }

    if (t < 16) {
      if (state == 0) {
        if (t == 0) {
          var zeros = 0;
          while (ip < ipEnd && input[ip] == 0) {
            ip++;
            zeros++;
          }
          if (ip >= ipEnd) throw const FormatException('LZO: input overrun');
          final offset = (zeros << 8) - zeros;
          t += offset + 15 + input[ip++];
        }
        t += 3;
        copyLiteral(t);
        state = 4;
        continue;
      } else if (state != 4) {
        final next = t & 3;
        var mPos = op - 1;
        mPos -= t >> 2;
        needIp(1);
        mPos -= input[ip++] << 2;
        copyMatch(2, mPos);
        matchNext(next);
        continue;
      } else {
        final next = t & 3;
        var mPos = op - (1 + 0x0800);
        mPos -= t >> 2;
        needIp(1);
        mPos -= input[ip++] << 2;
        copyMatch(3, mPos);
        matchNext(next);
        continue;
      }
    } else if (t >= 64) {
      final next = t & 3;
      var mPos = op - 1;
      mPos -= (t >> 2) & 7;
      needIp(1);
      mPos -= input[ip++] << 3;
      t = (t >> 5) - 1 + 2;
      copyMatch(t, mPos);
      matchNext(next);
      continue;
    } else if (t >= 32) {
      t = (t & 31) + 2;
      if (t == 2) {
        var zeros = 0;
        while (ip < ipEnd && input[ip] == 0) {
          ip++;
          zeros++;
        }
        if (ip >= ipEnd) throw const FormatException('LZO: input overrun');
        final offset = (zeros << 8) - zeros;
        t += offset + 31 + input[ip++];
      }
      needIp(2);
      var mPos = op - 1;
      var next = input[ip] | (input[ip + 1] << 8);
      ip += 2;
      mPos -= next >> 2;
      next &= 3;
      copyMatch(t, mPos);
      matchNext(next);
      continue;
    } else {
      // 16 <= t < 32
      needIp(2);
      var next = input[ip] | (input[ip + 1] << 8);
      var mPos = op;
      mPos -= (t & 8) << 11;
      t = (t & 7) + 2;
      if (t == 2) {
        var zeros = 0;
        while (ip < ipEnd && input[ip] == 0) {
          ip++;
          zeros++;
        }
        if (ip >= ipEnd) throw const FormatException('LZO: input overrun');
        final offset = (zeros << 8) - zeros;
        t += offset + 7 + input[ip++];
        next = input[ip] | (input[ip + 1] << 8);
      }
      ip += 2;
      mPos -= next >> 2;
      next &= 3;
      if (mPos == op) {
        eof = true;
        break;
      }
      mPos -= 0x4000;
      copyMatch(t, mPos);
      matchNext(next);
      continue;
    }
  }

  if (op != decompressedSize) {
    throw FormatException('LZO: 解压长度不符（$op / $decompressedSize）');
  }
  return out;
}
