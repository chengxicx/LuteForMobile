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

  // 与 web 端 lute/dict/service.py: strip_duplicate_headword 的测试用例
  // 一一对应：释义首行只是复述所查词（词头 + 可选【读音】注释）时删掉，
  // 其余情况原样保留。行为漂移会造成 mobile 与 web 词卡显示不一致。
  group('stripDuplicateHeadword', () {
    test('词头【读音】行被删掉', () {
      final gloss = '目覚まし時計【めざましどけい⑤】\n名\n闹钟。';
      expect(
        DictRepository.stripDuplicateHeadword(gloss, '目覚まし時計'),
        '名\n闹钟。',
      );
    });

    test('裸词头行被删掉', () {
      expect(
        DictRepository.stripDuplicateHeadword('たのしい\n愉快yúkuài', 'たのしい'),
        '愉快yúkuài',
      );
    });

    test('首行是别的词头：原样保留（读音命中的词条自己的词头是答案的一部分）', () {
      const gloss = '終わり\n【おわり】\n结束';
      expect(
        DictRepository.stripDuplicateHeadword(gloss, 'おわり'),
        gloss,
      );
    });

    test('首行词头后还有别的字符：保留（首行承载信息）', () {
      expect(
        DictRepository.stripDuplicateHeadword('箱は\n名\n箱子', '箱'),
        '箱は\n名\n箱子',
      );
      expect(
        DictRepository.stripDuplicateHeadword('終わりです。\n名', '終わり'),
        '終わりです。\n名',
      );
    });

    test('词条只有词头一行：不删（否则什么都不剩）', () {
      expect(
        DictRepository.stripDuplicateHeadword('たのしい', 'たのしい'),
        'たのしい',
      );
    });

    test('零宽空格不参与比较', () {
      expect(
        DictRepository.stripDuplicateHeadword('たのしい\n愉快', 'たの\u200bしい'),
        '愉快',
      );
    });

    test('空输入原样通过', () {
      expect(DictRepository.stripDuplicateHeadword(null, 'たのしい'), isNull);
      expect(DictRepository.stripDuplicateHeadword('', 'たのしい'), '');
      expect(DictRepository.stripDuplicateHeadword(' gloss\nmore', ''), ' gloss\nmore');
      expect(
        DictRepository.stripDuplicateHeadword(' gloss\nmore', '\u200b'),
        ' gloss\nmore',
      );
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
