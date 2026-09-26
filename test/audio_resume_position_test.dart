// Contract tests for the MP3 player's resume position.
//
// The position round-trip has two halves and they are on different sides of
// the wire:
//
//   * the app posts it every 2s (`POST /read/save_player_data`), which the
//     server writes to `books.BkAudioCurrentPos` -- this half works;
//   * the app reads it back off the page it renders, which is the half that
//     was silently broken.
//
// It broke because the read side looked for a DOM element the server no
// longer renders.  The old audio player rendered a hidden
// `input#book_audio_current_pos`; that player was removed and MP3 books now
// reuse the *video* player include, which carries the position as
// `LUTE_YT_DATA.startPos` instead.  `_extractAudioCurrentPos` kept querying
// the removed input, so it returned null for every book, `loadAudio` skipped
// its seek, and the player reopened at 00:00 -- while the database held the
// right number the whole time.
//
// Measured on a Leaf5C against the live server before the fix:
//   `BkAudioCurrentPos = 191.814` (03:11.8) in
//   `/opt/lute/lute_data/users/chengxi/lute.db`, and the reader showed
//   `00:00 / 05:24` both after backgrounding (HOME -> return, same Activity
//   instance) and after `am force-stop` + relaunch.
//
// These tests pin the read side to what the server actually emits, and pin
// that the legacy source still wins when a server does render it.

import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/html_parser.dart';
import 'package:song_mobile/features/reader/models/page_data.dart';

/// The page body carries the reading text; the player block may land in
/// either document depending on which endpoint served it.
const String _plainTextHtml = '<div id="thetext"></div>';

String _wrap(String scriptBody) {
  return '''
<script type="text/javascript">
  window.LUTE_YT_DATA = window.LUTE_YT_DATA || {};
$scriptBody
</script>
''';
}

/// The block an MP3 book actually gets: `videoId` is null (it is not a video
/// book) and `audioUrl` is set, which is what `PageData.hasAudio` keys off.
/// `startPos` is rendered as a bare number -- `{{ video_current_pos }}` is not
/// passed through `tojson`.
String _mp3Block({String startPos = '191.814'}) {
  return '''
  window.LUTE_YT_DATA.videoId = null;
  window.LUTE_YT_DATA.audioUrl = "/useraudio/stream/274";
  window.LUTE_YT_DATA.backend = "mp3";
  window.LUTE_YT_DATA.cues = [];
  window.LUTE_YT_DATA.words = [];
  window.LUTE_YT_DATA.bookId = 274;
  window.LUTE_YT_DATA.startPos = $startPos;
  window.LUTE_YT_DATA.langId = 2;
''';
}

/// The hidden field the *old* audio player used to render.
String _legacyPosInput(String seconds) {
  return '<input type="hidden" id="book_audio_current_pos" value="$seconds">';
}

PageData _parse(String textHtml, String metadataHtml) {
  return HtmlParser().parsePage(textHtml, metadataHtml, bookId: 274);
}

void main() {
  test('an mp3 page restores its position from LUTE_YT_DATA.startPos', () {
    // This is the regression: the page has no legacy input, so before the fix
    // `audioCurrentPos` came back null and the player reopened at 00:00.
    final page = _parse(_plainTextHtml, _wrap(_mp3Block()));

    expect(
      page.audioCurrentPos,
      isNotNull,
      reason: 'the position the server renders must reach PageData',
    );
    expect(page.audioCurrentPos, const Duration(milliseconds: 191814));
  });

  test('the fractional part survives, so a reopen resumes where it stopped', () {
    // The save side posts `inMilliseconds / 1000.0`, so truncating to whole
    // seconds here would move the listener backwards a little every reopen.
    final page = _parse(_plainTextHtml, _wrap(_mp3Block(startPos: '12.345')));

    expect(page.audioCurrentPos, const Duration(milliseconds: 12345));
  });

  test('the legacy hidden input still wins when a server renders it', () {
    // Backward compatibility: a server that still ships the old audio player
    // must keep working, and its value is the more specific one.
    final metadata = _wrap(_mp3Block(startPos: '191.814')) + _legacyPosInput('42.5');

    final page = _parse(_plainTextHtml, metadata);

    expect(page.audioCurrentPos, const Duration(milliseconds: 42500));
  });

  test('the player block is found in the text document too', () {
    // Which endpoint delivers the block varies (full `/read/<id>` vs the
    // per-page partial), so the scan must cover both documents.
    final page = _parse(_wrap(_mp3Block(startPos: '77')), _plainTextHtml);

    expect(page.audioCurrentPos, const Duration(milliseconds: 77000));
  });

  test('a page with no player block reports no position', () {
    // A plain text book renders no player include at all.  A null here is
    // what keeps the seek from happening; it must not be a fabricated 0.
    final page = _parse(_plainTextHtml, '<div id="pagedata"></div>');

    expect(page.audioCurrentPos, isNull);
  });

  test('startPos of 0 is a position, not a missing one', () {
    // A book that was never played renders `startPos = 0`.  It must not be
    // mistaken for "the block is absent" -- though both skip the seek, only
    // the second is a parse failure worth noticing.
    final page = _parse(_plainTextHtml, _wrap(_mp3Block(startPos: '0')));

    expect(page.audioCurrentPos, Duration.zero);
  });

  test('an mp3 block still does not activate the video player', () {
    // Guard on the neighbouring contract: `startPos` is now read from the
    // shared block, and that must not make an MP3 book look like a YouTube
    // one (which would swap the audio player for an iframe).
    final page = _parse(_plainTextHtml, _wrap(_mp3Block()));

    expect(page.youtube, isNull);
    expect(page.isYoutube, isFalse);
    expect(page.hasAudio, isTrue);
  });
}
