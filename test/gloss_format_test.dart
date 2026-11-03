import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/dict_repository.dart';
import 'package:song_mobile/core/dict/gloss_format.dart';

void main() {
  group('parse_gloss：MOJi 辞書 所 的 See also 指针', () {
    // 真机（Leaf5C）上 所 命中的裸词条：只有三行指针，没有任何释义。
    const stub = 'See also: 所【どころ◎③】\n'
        'See also: 所【ところ◎③】\n'
        'See also: 所【とこ②】';

    test('指针条目没有义项，不能被当成「第一个义项」', () {
      expect(glossSenses(stub), isEmpty);
      expect(firstSense(stub), isNull);
      expect(firstSense(DictRepository.stripDuplicateHeadword('所\n$stub', '所')),
          isNull);
    });

    test('指针按词典原始顺序取出，并带读音', () {
      final xrefs = glossXrefs(stub);
      expect(xrefs.map((b) => b.text).toList(), ['所', '所', '所']);
      expect(
        xrefs.map((b) => b.reading).toList(),
        ['どころ◎③', 'ところ◎③', 'とこ②'],
      );
    });
  });

  group('parse_gloss：指针解析后的 所【どころ◎③】', () {
    const resolved = '''
名副助詞
名
值得……的地方，应该……的地方（すべきところ）。
見所。
值得看的地方；所见。
聞き所。
值得听的地方；所闻。
つかみ所。
抓手； 抓挠儿。
生产……地方（生産地）。
茶所。
产茶区。
米所。
稻米产地。
副助詞
岂止……，岂但……，慢说……（就连……也……），哪谈得上。
それ所じゃない。
岂止是那样。
痛い所の騒ぎじゃない。
岂但是疼（简直疼得要命）。
落ち着いて勉強する所じゃない。
哪里能沉下心来学习（根本就不能沉下心来学习）。
''';

    test('只把真正的释义当义项，例句与例句译文不算', () {
      expect(glossSenses(resolved), [
        '值得……的地方，应该……的地方（すべきところ）。',
        '生产……地方（生産地）。',
        '米所。',
      ]);
    });

    test('第一个义项与 web 的 first_sense 是同一行', () {
      expect(firstSense(resolved), '值得……的地方，应该……的地方（すべきところ）。');
    });
  });

  group('parse_gloss：编号/词性前缀的多义项', () {
    test('中文词典的编号义项（与 web 一样：带句号的下一句会被当成例句）', () {
      const gloss = '1. 处所，地方\n2. 用于房屋等';
      expect(glossSenses(gloss), ['处所，地方', '用于房屋等']);
      // web 端的实际行为：前一条是义项、本条以句号收尾、且没有假名，
      // 会被 汉德 分支当成例句，而不是第 2 条义项。
      expect(glossSenses('1. 处所，地方。\n2. 用于房屋等。'), ['处所，地方。']);
    });

    test('中文词性前缀的行是义项，但下一句会被当成它的例句', () {
      const gloss = '名 处所，地方。\n量 用于房屋等。';
      expect(glossSenses(gloss), ['处所，地方。']);
    });

    test('英文词典的编号义项按编号顺序', () {
      const gloss = 'v. 跑；奔跑\nn. 奔跑；一段路程';
      expect(glossSenses(gloss), ['跑；奔跑', '奔跑；一段路程']);
    });

    test('种子释义不算义项（编号进入 sense.number）', () {
      const gloss = '1. 跑\n2. 经营';
      final blocks = parseGloss(gloss);
      final senses = blocks.where((b) => b.type == 'sense').toList();
      expect(senses.map((b) => b.text).toList(), ['跑', '经营']);
      expect(senses.map((b) => b.number).toList(), [1, 2]);
    });
  });

  group('autoFillTranslation：建卡预填优先级', () {
    test('已有翻译不动', () {
      expect(
        autoFillTranslation(
          existing: '已有的翻译',
          chosen: '用户切过的义项',
          gloss: '1. 词典第一条',
        ),
        '已有的翻译',
      );
    });

    test('用户切过义项就用切换的那条', () {
      expect(
        autoFillTranslation(
          existing: '',
          chosen: '用户切过的义项',
          gloss: '1. 词典第一条',
        ),
        '用户切过的义项',
      );
    });

    test('没切过则取词典第一条（空白也算没切）', () {
      expect(
        autoFillTranslation(existing: '  ', chosen: ' ', gloss: '1. 词典第一条'),
        '词典第一条',
      );
    });

    test('词典没命中时返回 null，表单保持空白', () {
      expect(autoFillTranslation(existing: null, chosen: null, gloss: null),
          isNull);
    });
  });

  group('homographCandidates：带读音优先查复合键', () {
    test('先复合键、再裸读音、最后裸词条', () {
      expect(
        DictRepository.homographCandidates('所', 'どころ◎③'),
        ['所【どころ◎③】', '所(どころ◎③)', 'どころ◎③', '所【どころ◎】', '所(どころ◎)', 'どころ◎', '所'],
      );
    });

    test('末位的圈号会剥掉再做一次复合键（◎ 不剥）', () {
      final candidates = DictRepository.homographCandidates('食べる', 'たべる①');
      expect(candidates.first, '食べる【たべる①】');
      expect(candidates, contains('食べる【たべる】'));
    });

    test('没有读音时只查裸词条', () {
      expect(DictRepository.homographCandidates('run', null), ['run']);
    });
  });
}
