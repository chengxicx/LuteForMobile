import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/dict/dict_repository.dart';

// 本地词典的查询候选链：词典键是假名读音且不带敬语前缀（小学馆V2日汉
// 实测：おひさしぶり 在键里是 ひさしぶり），所以查询按 原文 → 读音 →
// 去敬语前缀 逐级尝试。这是纯函数，锁住候选顺序与去重。
void main() {
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
}
