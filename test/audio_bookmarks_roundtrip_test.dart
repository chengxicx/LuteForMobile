// Contract tests for MP3 bookmarks, both halves of the round trip.
//
// This one is nastier than the position bug it sits next to, because the
// damage is destructive: the app does not merely fail to *show* the stored
// bookmarks, it *erases* them.  Measured on a Leaf5C against the live server
// (2026-09-27): book 274 held `BkAudioBookmarks = "86.989"` in
// `/opt/lute/lute_data/users/chengxi/lute.db`; opening the book and letting
// the 2s auto-save fire once turned it into NULL.  Not one book in the
// library still had a bookmark left.
//
// The chain had three links, and every one of them had to be fixed:
//
//   1. **Read.** The server renders the stored bookmarks as
//      `LUTE_YT_DATA.bookmarks` (`read/youtube_player.html`); nothing on the
//      client ever looked at it.  The page was parsed, the bookmarks were
//      dropped on the floor, and `PageData.audioBookmarks` was hardcoded to
//      `const []`.
//   2. **Distinguish "none" from "unknown".** An empty list is a fact about
//      the book; a missing field is a fact about the *page*.  Collapsing
//      them (`List<double>` with a `const []` default) meant every reopen
//      asserted "this book has no bookmarks".
//   3. **Write.** `_savePosition` posted that fabricated `[]` every 2 s to
//      `POST /read/save_player_data`, and the server assigned it
//      unconditionally -- `book.audio_bookmarks = data.get("bookmarks")`.
//      Empty list in, NULL out, forever.
//
// So the contract has three parts and the tests below cover all of them:
// parse the payload, keep null distinct from `[]`, and never post the field
// unless the page actually told us something.  The write side is asserted
// against a recording HTTP adapter, because the bug lived in the request
// body -- a test that stops at the parsed object would have passed while the
// database burned.
//
// Server half (already deployed): `read/routes.py` gained
// `if "bookmarks" in data:` guards on both save routes, and the reader
// context now passes `video_bookmarks=book.audio_bookmarks or ""`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';

const String _plainTextHtml = '<div id="thetext"></div>';

String _wrap(String scriptBody) {
  return '''
<script type="text/javascript">
  window.LUTE_YT_DATA = window.LUTE_YT_DATA || {};
$scriptBody
</script>
''';
}

/// The block an MP3 book actually gets.  `bookmarks` is rendered through
/// `tojson`, so it is always a *quoted* JS string -- `""` when the book has
/// none -- and it is omitted entirely by servers that predate the fix.
String _mp3Block({String? bookmarks = '"86.989"'}) {
  final line = bookmarks == null
      ? ''
      : '  window.LUTE_YT_DATA.bookmarks = $bookmarks;\n';
  return '''
  window.LUTE_YT_DATA.videoId = null;
  window.LUTE_YT_DATA.audioUrl = "/useraudio/stream/274";
  window.LUTE_YT_DATA.backend = "mp3";
  window.LUTE_YT_DATA.cues = [];
  window.LUTE_YT_DATA.words = [];
  window.LUTE_YT_DATA.bookId = 274;
  window.LUTE_YT_DATA.startPos = 191.814;
  window.LUTE_YT_DATA.langId = 2;
$line''';
}

/// The hidden field the *old* audio player used to render.
String _legacyBookmarkInput(String value) {
  return '<input type="hidden" id="book_audio_bookmarks" value="$value">';
}

PageData _parse(String textHtml, String metadataHtml) {
  return HtmlParser().parsePage(textHtml, metadataHtml, bookId: 274);
}

/// Records what actually went out on the wire.  `ApiService` takes an
/// injectable `Dio`, so the only thing faked here is the socket.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  RequestOptions get lastRequest => requests.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      'OK',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.textPlainContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Dio hands the adapter either the raw `Map` or the encoded JSON string
/// depending on where the transformer sits in the pipeline; accept both so
/// the assertion is about the payload, not about Dio's internals.
Map<String, dynamic> _bodyOf(RequestOptions options) {
  final data = options.data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return jsonDecode(data as String) as Map<String, dynamic>;
}

void main() {
  group('reading the stored bookmarks off the page', () {
    test('the semicolon payload the server renders is parsed', () {
      // The column stores what the mobile client posted:
      // `bookmarks.map((b) => b.toString()).join(';')`, and the reader hands
      // it back verbatim.  This is the regression: before the fix nothing
      // read this assignment, so a book with a bookmark reopened showing
      // none.
      final page = _parse(_plainTextHtml, _wrap(_mp3Block()));

      expect(page.audioBookmarks, isNotNull);
      expect(page.audioBookmarks, [86.989]);
    });

    test('several bookmarks survive, in order', () {
      final page = _parse(
        _plainTextHtml,
        _wrap(_mp3Block(bookmarks: '"12.5;86.989;100"')),
      );

      expect(page.audioBookmarks, [12.5, 86.989, 100.0]);
    });

    test('a book with no bookmarks reports an empty list, not null', () {
      // `tojson` renders an empty column as `""`, and that is the server
      // stating a fact: this book has none.  It is writable-back.
      final page = _parse(_plainTextHtml, _wrap(_mp3Block(bookmarks: '""')));

      expect(page.audioBookmarks, isNotNull);
      expect(page.audioBookmarks, isEmpty);
    });

    test('a page that never mentions bookmarks reports null', () {
      // The load-bearing distinction.  A server that does not send the
      // assignment has told us nothing, and "nothing" must not be written
      // back -- that is precisely how the library got wiped.
      final page = _parse(_plainTextHtml, _wrap(_mp3Block(bookmarks: null)));

      expect(
        page.audioBookmarks,
        isNull,
        reason: 'null means "the page did not tell us"; [] means "it told us there are none"',
      );
    });

    test('a JSON array payload is still understood', () {
      // Older servers (and the web player) have stored bookmarks as a JSON
      // array; the reader must not lose those books.
      final page = _parse(
        _plainTextHtml,
        _wrap(_mp3Block(bookmarks: '"[12.5, 86.989]"')),
      );

      expect(page.audioBookmarks, [12.5, 86.989]);
    });

    test('the legacy hidden input wins, and its empty value is authoritative', () {
      // Backward compatibility with a server that still renders the old
      // audio player, mirroring the position tests.  The empty case is the
      // interesting one: an explicitly empty legacy field is the server
      // saying "none", so it must come back as [] and not fall through to
      // the other source.
      final withValue = _wrap(_mp3Block(bookmarks: '""')) +
          _legacyBookmarkInput('42.5');
      expect(_parse(_plainTextHtml, withValue).audioBookmarks, [42.5]);

      final empty = _wrap(_mp3Block()) + _legacyBookmarkInput('');
      final page = _parse(_plainTextHtml, empty);
      expect(page.audioBookmarks, isNotNull);
      expect(page.audioBookmarks, isEmpty);
    });

    test('the player block is found in the text document too', () {
      // Which endpoint delivers the include varies (full `/read/<id>` vs the
      // per-page partial), so both documents are scanned.
      final page = _parse(_wrap(_mp3Block()), _plainTextHtml);

      expect(page.audioBookmarks, [86.989]);
    });

    test('a malformed payload degrades to empty instead of throwing', () {
      // A corrupt column must not take the player down with it.
      final page = _parse(
        _plainTextHtml,
        _wrap(_mp3Block(bookmarks: '"garbage;;not-a-number"')),
      );

      expect(page.audioBookmarks, isEmpty);
    });
  });

  group('writing the bookmarks back', () {
    late _RecordingAdapter adapter;
    late ApiService api;

    setUp(() {
      adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      api = ApiService(baseUrl: 'http://lute.invalid', dio: dio);
    });

    test('null bookmarks are omitted from the body entirely', () async {
      // THE fix.  Not "posted as empty" -- absent.  The server keys off
      // `"bookmarks" in data`, so an omitted key leaves the column alone.
      await api.postUnifiedPlayerData(274, 191.814, null);

      final body = _bodyOf(adapter.lastRequest);
      expect(
        body.containsKey('bookmarks'),
        isFalse,
        reason: 'posting a key we never loaded is what NULLed every bookmark in the library',
      );
      expect(body['bookid'], 274);
      expect(body['position'], 191.814);
    });

    test('an empty list is posted, because that one is a real statement', () async {
      // The mirror of the previous test: [] came from the page, so it is
      // allowed to overwrite.  The server reads the empty string back as
      // "no bookmarks" (`book.audio_bookmarks or ""`).
      await api.postUnifiedPlayerData(274, 191.814, const []);

      final body = _bodyOf(adapter.lastRequest);
      expect(body.containsKey('bookmarks'), isTrue);
      expect(body['bookmarks'], '');
    });

    test('bookmarks go out in the semicolon shape the server stores', () async {
      await api.postUnifiedPlayerData(274, 191.814, const [12.5, 86.989]);

      expect(_bodyOf(adapter.lastRequest)['bookmarks'], '12.5;86.989');
    });

    test('the write goes to the shared player route, not the legacy one', () async {
      // `save_youtube_player_data` is the route the shared media engine
      // posts to for every backend it drives, MP3 included; the old
      // `save_player_data` is the leftover the app used to call.  Both
      // write `BkAudioCurrentPos`, so a wrong route still "works" for
      // position -- which is exactly why it needs pinning.
      await api.postUnifiedPlayerData(274, 1.0, null);

      expect(
        adapter.lastRequest.uri.path,
        '/read/save_youtube_player_data',
      );
    });
  });
}
