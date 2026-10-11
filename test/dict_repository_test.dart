import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/dict_repository.dart';

// 本地词典的查询候选链：词典键是假名读音且不带敬语前缀（小学馆V2日汉
// 实测：おひさしぶり 在键里是 ひさしぶり），所以查询按 原文 → 读音 →
// 去敬语前缀 逐级尝试。这是纯函数，锁住候选顺序与去重。
void main() {
  group('lookupCandidates', () {
    test('只有词条原文', () {
      expect(DictRepository.lookupCandidates('箱', null), ['箱']);
    });

    test('原文 + 读音，原文优先且去重', () {
      final list = DictRepository.lookupCandidates('たのしい', 'たのしい');
      expect(list, ['たのしい']);
    });

    test('读音带敬语前缀：お/ご 各生成一个去前缀候选', () {
      expect(
        DictRepository.lookupCandidates('お久しぶり', 'おひさしぶり'),
        ['お久しぶり', 'おひさしぶり', 'ひさしぶり'],
      );
      expect(
        DictRepository.lookupCandidates('ご飯', 'ごはん'),
        ['ご飯', 'ごはん', 'はん'],
      );
    });

    test('读音为空：只有原文，不产生空候选', () {
      expect(DictRepository.lookupCandidates('ね', ''), ['ね']);
    });
  });

  // 词典池模型：下载/导入与语言解耦，选用关系按语言各存一份 key。
  // 这两个纯函数决定持久化 key 与池内文件名，改名会让老用户的选择
  //  silently 失效，锁住。
  group('selectionKey', () {
    test('按语言 id 各存一份', () {
      expect(DictRepository.selectionKey(13), 'dict_for_lang_13');
      expect(DictRepository.selectionKey(1), 'dict_for_lang_1');
    });
  });

  group('poolFileNameForMdx', () {
    test('普通文件名：去扩展名加 .db', () {
      expect(
        DictRepository.poolFileNameForMdx('/sdcard/Download/oxford.mdx'),
        'oxford.db',
      );
    });

    test('无扩展名也加 .db', () {
      expect(
        DictRepository.poolFileNameForMdx('/sdcard/plainname'),
        'plainname.db',
      );
    });

    test('中日韩文件名原样保留（只洗路径/控制字符）', () {
      expect(
        DictRepository.poolFileNameForMdx('/下载/小学馆日汉词典.mdx'),
        '小学馆日汉词典.db',
      );
    });

    test('路径分隔符与非法字符洗成下划线', () {
      expect(
        DictRepository.poolFileNameForMdx(r'a/b\c:d*e?f"g<h>i|j.mdx'),
        'b_c_d_e_f_g_h_i_j.db',
      );
    });

    test('名字洗成全空时回落 imported.db', () {
      expect(DictRepository.poolFileNameForMdx('///'), 'imported.db');
      expect(DictRepository.poolFileNameForMdx('_'), 'imported.db');
    });

    test('超长名字截到 80 字符', () {
      final long = 'x' * 200;
      final name = DictRepository.poolFileNameForMdx('$long.mdx');
      expect(name, '${'x' * 80}.db');
    });
  });
}
