import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:song_mobile/features/local_books/services/local_book_store.dart';
import 'package:song_mobile/features/local_books/services/local_epub_import.dart';

void main() {
  late Directory temp;
  late Directory boxDir;
  late LocalBookStore store;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    temp = await Directory.systemTemp.createTemp('local_book_store_');
    boxDir = await Directory.systemTemp.createTemp('local_book_hive_');
    // Pre-open the box so the store never touches path_provider.
    Hive.init(boxDir.path);
    await Hive.openBox<String>('local_books_test');
    SharedPreferences.setMockInitialValues({});
    store = LocalBookStore(rootDir: temp.path, boxName: 'local_books_test');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
    await boxDir.delete(recursive: true);
  });

  LocalBookRecord record(String id, {int importedAt = 1}) => LocalBookRecord(
    id: id,
    title: 'Book $id',
    author: 'A',
    chapterCount: 3,
    importedAt: importedAt,
  );

  test('upsert / list (newest first) / get', () async {
    await store.upsert(record('b1', importedAt: 100));
    await store.upsert(record('b2', importedAt: 200));

    final list = await store.list();
    expect(list.map((b) => b.id), ['b2', 'b1']);

    final got = await store.get('b1');
    expect(got?.title, 'Book b1');
    expect(await store.get('missing'), isNull);
  });

  test('last chapter, dictionary and server book id updates', () async {
    await store.upsert(record('b1'));

    await store.setLastChapter('b1', 2);
    await store.setDictFilename('b1', 'moji.db');
    await store.setServerBookId('b1', 42);

    final got = await store.get('b1');
    expect(got?.lastChapter, 2);
    expect(got?.dictFilename, 'moji.db');
    expect(got?.serverBookId, 42);

    // Clearing the dictionary choice is expressible.
    await store.setDictFilename('b1', null);
    expect((await store.get('b1'))?.dictFilename, isNull);
  });

  test('book.json roundtrip and epub path', () async {
    final dir = await store.bookDir('b1');
    await Directory(dir).create(recursive: true);
    final data = LocalEpubData(
      id: 'b1',
      title: '雪国',
      author: 'Kawabata',
      chapters: const [
        LocalEpubChapterInfo(path: 'OEBPS/ch1.xhtml', title: 'One'),
        LocalEpubChapterInfo(
          path: 'OEBPS/f.xhtml',
          title: 'Fixed',
          viewportWidth: 768,
          viewportHeight: 1024,
        ),
      ],
    );
    await File('$dir/book.json').writeAsString(
      '{"id":"b1","title":"雪国","author":"Kawabata","chapters":['
      '{"path":"OEBPS/ch1.xhtml","title":"One"},'
      '{"path":"OEBPS/f.xhtml","title":"Fixed","vw":768,"vh":1024}]}',
    );
    await File('$dir/book.epub').writeAsBytes([1, 2, 3]);

    final loaded = await store.loadBookData('b1');
    expect(loaded?.chapters[1].viewportWidth, 768);
    expect(await store.epubFilePath('b1'), '$dir/book.epub');
    expect(data.title, '雪国');
  });

  test('chapter scroll persists per chapter', () async {
    await store.saveChapterScroll('b1', 0, 12.5);
    await store.saveChapterScroll('b1', 1, 88.0);
    expect(await store.chapterScroll('b1', 0), 12.5);
    expect(await store.chapterScroll('b1', 1), 88.0);
    expect(await store.chapterScroll('b1', 2), 0);
  });

  test('delete removes record and directory', () async {
    await store.upsert(record('b1'));
    final dir = Directory(await store.bookDir('b1'));
    await dir.create(recursive: true);
    await File('${dir.path}/book.json').writeAsString('{}');

    await store.delete('b1');

    expect(await store.get('b1'), isNull);
    expect(await dir.exists(), isFalse);
  });

  test('disk usage counts book files', () async {
    expect(await store.diskUsageBytes(), 0);
    final dir = Directory(await store.bookDir('b1'));
    await dir.create(recursive: true);
    await File('${dir.path}/book.epub').writeAsBytes(List.filled(10, 1));
    expect(await store.diskUsageBytes(), 10);
  });
}
