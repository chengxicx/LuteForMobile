import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/local_books/services/local_epub_import.dart';

/// Builds a minimal but well-formed EPUB zip in memory.  Chapter 1
/// carries the payload the sanitizer must survive (script, onclick,
/// javascript: link); chapter 3 declares a pixel viewport (fixed
/// layout); the nav document gives chapters their TOC titles.
List<int> buildTestEpub() {
  final archive = Archive();

  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  void addBinary(String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?>'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OEBPS/content.opf',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="uid">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>雪国</dc:title>'
    '<dc:creator>Kawabata</dc:creator>'
    '</metadata>'
    '<manifest>'
    '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    '<item id="css" href="styles/style.css" media-type="text/css"/>'
    '<item id="img1" href="images/cover.jpg" media-type="image/jpeg"/>'
    '<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c3" href="text/fixed.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest>'
    '<spine>'
    '<itemref idref="c1"/>'
    '<itemref idref="c2"/>'
    '<itemref idref="c3"/>'
    '</spine>'
    '</package>',
  );
  add(
    'OEBPS/nav.xhtml',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<body><nav epub:type="toc"><ol>'
    '<li><a href="text/ch1.xhtml">Night Train</a></li>'
    '<li><a href="text/ch2.xhtml#frag">Mirror</a></li>'
    '</ol></nav></body></html>',
  );
  add(
    'OEBPS/text/ch1.xhtml',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    '<title>ch1</title>'
    '<link rel="stylesheet" type="text/css" href="../styles/style.css"/>'
    '</head><body>'
    '<script>alert("evil")</script>'
    '<p onclick="hack()">The <a href="javascript:boom()">train</a> came out of the long tunnel.</p>'
    '<p><img src="../images/cover.jpg" alt="cover"/></p>'
    '</body></html>',
  );
  add(
    'OEBPS/text/ch2.xhtml',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>ch2</title></head>'
    '<body><p>国境の長いトンネルを抜けると雪国であった。</p></body></html>',
  );
  add(
    'OEBPS/text/fixed.xhtml',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    '<meta name="viewport" content="width=768, height=1024"/>'
    '</head><body><p>fixed page</p></body></html>',
  );
  add('OEBPS/styles/style.css', 'p { color: #222; }\n');
  addBinary('OEBPS/images/cover.jpg', [1, 2, 3, 4, 5]);

  return ZipEncoder().encode(archive);
}

void main() {
  late Directory temp;
  late LocalEpubImporter importer;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local_epub_import_');
    importer = LocalEpubImporter(resolveRoot: () async => temp.path);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('parses metadata, spine order, TOC titles and fixed layout',
      () async {
    final data = await importer.importFromBytes(buildTestEpub());

    expect(data.title, '雪国');
    expect(data.author, 'Kawabata');
    expect(data.chapters.length, 3);

    expect(data.chapters[0].path, 'OEBPS/text/ch1.xhtml');
    expect(data.chapters[0].title, 'Night Train');
    expect(data.chapters[0].viewportWidth, isNull);

    // TOC href fragments are stripped when matching.
    expect(data.chapters[1].title, 'Mirror');

    expect(data.chapters[2].viewportWidth, 768);
    expect(data.chapters[2].viewportHeight, 1024);
  });

  test('chapter pages are sanitised and rewritten in place', () async {
    final data = await importer.importFromBytes(buildTestEpub());

    final ch1 = await File(
      '${temp.path}/${data.id}/extract/OEBPS/text/ch1.xhtml',
    ).readAsString();
    // Active content gone (the page's own bridge script remains, so
    // assert on the payloads, not on the tag itself).
    expect(ch1, isNot(contains('alert(')));
    expect(ch1, isNot(contains('hack()')));
    expect(ch1, isNot(contains('onclick')));
    expect(ch1, isNot(contains('javascript:')));
    // Active content gone, content and links kept.
    expect(ch1, contains('long tunnel'));
    expect(ch1, contains('train'));
    // The standalone-page contract with the reader.
    expect(ch1, contains('epub-body'));
    expect(ch1, contains('LuteLocalBridge'));
    expect(ch1, contains('localEpubLookup'));
    // Relative references untouched: served at mirrored zip paths.
    expect(ch1, contains('../styles/style.css'));
    expect(ch1, contains('../images/cover.jpg'));
  });

  test('assets are mirrored at their zip paths and book.json written',
      () async {
    final data = await importer.importFromBytes(buildTestEpub());

    final img = File('${temp.path}/${data.id}/extract/OEBPS/images/cover.jpg');
    expect(await img.exists(), isTrue);
    expect(await img.readAsBytes(), [1, 2, 3, 4, 5]);
    // mimetype / META-INF are not extracted.
    expect(
      await File('${temp.path}/${data.id}/extract/META-INF/container.xml')
          .exists(),
      isFalse,
    );

    final epub = File('${temp.path}/${data.id}/book.epub');
    expect(await epub.exists(), isTrue);

    final json = File('${temp.path}/${data.id}/book.json');
    final decoded = jsonDecode(await json.readAsString())
        as Map<String, dynamic>;
    expect(decoded['title'], '雪国');
    final reloaded = LocalEpubData.fromJson(decoded);
    expect(reloaded.chapters.length, 3);
  });

  test('a non-zip is refused with a readable message', () async {
    await expectLater(
      importer.importFromBytes(utf8.encode('this is not a zip')),
      throwsA(isA<LocalEpubImportException>()),
    );
  });

  test('a zip without container.xml is refused', () async {
    final archive = Archive();
    final bytes = utf8.encode('<html/>');
    archive.addFile(ArchiveFile('a.html', bytes.length, bytes));
    await expectLater(
      importer.importFromBytes(ZipEncoder().encode(archive)),
      throwsA(isA<LocalEpubImportException>()),
    );
  });
}
