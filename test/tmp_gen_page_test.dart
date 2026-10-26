import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/local_books/services/local_epub_page.dart';

void main() {
  test('gen page to /tmp', () {
    final page = buildLocalChapterPage(
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一話</title></head>'
      '<body><h1>第一話</h1><p>朝の電車の中で、猫を見かけた。とても静かだった。</p></body></html>',
    );
    File('/tmp/gen_ch1.html').writeAsStringSync(page.html);
    expect(page.html, isNotEmpty);
  });
}
