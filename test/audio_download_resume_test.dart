// 音频缓存断点续传的判定 —— 直接决定"被掐掉的一次下载要不要白扔"。
//
// 起因（2026-10-10，手机 diag.log）：
//   00:17:49 GET /useraudio/stream/297 200 rt=3.841 bs=52826112      <- 中断
//   00:18:03 GET /useraudio/stream/297 200 rt=7.911 bs=64231987      <- 完整重下
// 旧实现 `_downloadAudioToFile` 失败时删掉 `.part`，下次必然从 0 重来，
// 白耗 52MB。改成续传之后，"从哪个字节接着写"这件事必须钉死：接错位置会
// 得到一个长度对、内容坏的缓存文件，比白下流量糟得多。

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/utils/audio_download_resume.dart';

void main() {
  group('resumeWriteOffset', () {
    test('服务端按我们给的起点回了 206 时，接着已有的字节写', () {
      expect(
        resumeWriteOffset(
          existing: 52826112,
          status: 206,
          contentRange: 'bytes 52826112-64231986/64231987',
        ),
        52826112,
      );
    });

    test('没有半截文件时从头写（不发 Range 的普通下载）', () {
      expect(
        resumeWriteOffset(existing: 0, status: 200, contentRange: null),
        0,
      );
    });

    test('服务端不支持 Range（回 200）时从头重写，不能追加', () {
      // 追加会把整份内容接在半截文件后面：长度看着对，内容是坏的。
      expect(
        resumeWriteOffset(
          existing: 52826112,
          status: 200,
          contentRange: null,
        ),
        0,
      );
    });

    test('Content-Range 的起点和我们手上的字节数不一致时从头重写', () {
      // 服务端换了文件（`?v=` 变了 / 重新上传）而我们还拿着旧页面的 URL。
      expect(
        resumeWriteOffset(
          existing: 52826112,
          status: 206,
          contentRange: 'bytes 0-64231986/64231987',
        ),
        0,
      );
    });

    test('没有 Content-Range 头的 206 也不追加（无从核对起点）', () {
      expect(
        resumeWriteOffset(existing: 1024, status: 206, contentRange: null),
        0,
      );
    });
  });

  group('contentRange 解析', () {
    test('起点与总长', () {
      expect(contentRangeStart('bytes 100-999/1000'), 100);
      expect(contentRangeTotal('bytes 100-999/1000'), 1000);
    });

    test('容忍前后空白', () {
      expect(contentRangeStart('  bytes 42-99/100  '), 42);
    });

    test('解析不出来时返回 null，而不是瞎猜一个数', () {
      expect(contentRangeStart(null), isNull);
      expect(contentRangeTotal(''), isNull);
      expect(contentRangeStart('bytes */1000'), isNull);
      expect(contentRangeTotal('garbage'), isNull);
    });

    test('总长是 * 时只有起点可用', () {
      expect(contentRangeStart('bytes 10-19/*'), 10);
      expect(contentRangeTotal('bytes 10-19/*'), isNull);
    });
  });
}
