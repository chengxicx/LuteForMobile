import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/services/epub_offline_html.dart';

/// A minimal `/read/epub_render` page carrying exactly the markers the
/// server template (and its pinned tests in lute-v3) guarantees:
/// the look class, the boot `var look` line, LUTE_FURIGANA,
/// furiganaLoaded / tripleEnabled, the reader script tag, the two data
/// css attributes and the tokens JSON.
const String samplePage = '''
<!DOCTYPE html>
<html lang="ltr">
<head>
  <meta charset="utf-8">
  <title>Chapter 1</title>
  <link rel="stylesheet" type="text/css" href="/static/css/styles.css?v=abc123">
  <link rel="stylesheet" type="text/css" href="/theme/current?v=t1">
  <script type="text/javascript">
    var LUTE_FURIGANA = { enabled: false, langId: 9, script: "japanese" };
  </script>
  <script type="text/javascript" src="/static/js/lute-epub-reader.js?v=r1" charset="utf-8" defer></script>
</head>
<body>
  <h1 id="thetexttitle" class="hide">Chapter 1</h1>
  <div id="thetext" class="epub-text-container epub-look-original">
    <div id="epub-chapter"
         data-epub-css="/static/epub/u1/lute.css"
         data-epub-orig-css="/static/epub/u1/lute-orig.css"><p class="epub-body" style="background: url('/static/epub/u1/img/bg.png')">Hello <img src="/static/epub/u1/img/ch1.jpg" alt=""> world.</p></div>
  </div>
  <script type="application/json" id="lute-epub-tokens">[["hello",12,1,0,0],[" ",0,-1,0,0],["world",0,-1,0,0],["猫",13,0,1,1],["が",14,1,1,1],["好き",0,-1,1,1],["。",0,-1,1,1],["犬",15,0,2,2]]</script>
  <script type="application/json" id="lute-epub-substitutions">[["’","'"]]</script>
  <script>
  (function () {
    "use strict";
    var FURIGANA_SRC = "/static/js/lute-furigana.js?v=f1";
    var furiganaLoaded = false;
    var tripleEnabled = false;
    document.addEventListener("DOMContentLoaded", function () {
      var look = "original";
      window.EpubReader.mount(document.getElementById("epub-chapter"));
    });
  })();
  </script>
</body>
</html>
''';

void main() {
  group('rewriteEpubRenderHtml', () {
    test('canonical params are a no-op', () {
      final out = rewriteEpubRenderHtml(
        samplePage,
        look: 'original',
        furigana: false,
        triple: false,
      );
      expect(out, samplePage);
    });

    test('look=night swaps the class and the boot look', () {
      final out = rewriteEpubRenderHtml(
        samplePage,
        look: 'night',
        furigana: false,
        triple: false,
      );
      expect(out, contains('epub-text-container epub-look-night'));
      expect(out, isNot(contains('epub-look-original')));
      expect(out, contains('var look = "night";'));
    });

    test('look=theme drops the look class entirely', () {
      final out = rewriteEpubRenderHtml(
        samplePage,
        look: 'theme',
        furigana: false,
        triple: false,
      );
      expect(out, contains('class="epub-text-container"'));
      expect(out, isNot(contains('epub-look-')));
      expect(out, contains('var look = "theme";'));
    });

    test('furigana flips the flags and injects the script before the reader js',
        () {
      final out = rewriteEpubRenderHtml(
        samplePage,
        look: 'original',
        furigana: true,
        triple: false,
      );
      expect(out, contains('var LUTE_FURIGANA = { enabled: true'));
      expect(out, contains('var furiganaLoaded = true;'));
      final injected = out.indexOf('src="/static/js/lute-furigana.js"');
      final reader = out.indexOf('lute-epub-reader.js');
      expect(injected, greaterThan(0));
      expect(injected, lessThan(reader));
    });

    test('triple flips the flag', () {
      final out = rewriteEpubRenderHtml(
        samplePage,
        look: 'original',
        furigana: false,
        triple: true,
      );
      expect(out, contains('var tripleEnabled = true;'));
      expect(out, isNot(contains('var tripleEnabled = false;')));
    });

    test('pages without the markers pass through untouched', () {
      const plain = '<html><body>no markers here</body></html>';
      expect(
        rewriteEpubRenderHtml(plain, look: 'night', furigana: true, triple: true),
        plain,
      );
    });
  });

  group('extractAssetPaths', () {
    test('collects stylesheets, scripts, images, data-css and inline url()',
        () {
      final paths = extractAssetPaths(
        samplePage,
        serverOrigin: 'https://lute.example.com',
      );
      expect(paths, containsAll(<String>[
        'static/css/styles.css',
        'theme/current',
        'static/js/lute-epub-reader.js',
        'static/epub/u1/lute.css',
        'static/epub/u1/lute-orig.css',
        'static/epub/u1/img/ch1.jpg',
        'static/epub/u1/img/bg.png',
      ]));
    });

    test('foreign origins and data urls are not storable', () {
      const html = '''
        <html><head>
        <link rel="stylesheet" href="https://cdn.example.com/x.css">
        <script src="data:application/javascript,xxx"></script>
        </head><body>
        <img src="/static/epub/u1/ok.png">
        </body></html>
      ''';
      final paths = extractAssetPaths(html, serverOrigin: 'https://s.example');
      expect(paths, {'static/epub/u1/ok.png'});
    });

    test('srcset candidates are collected', () {
      const html = '''
        <html><body>
        <img src="/static/epub/u1/base.jpg"
             srcset="/static/epub/u1/a.jpg 1x, /static/epub/u1/b.jpg 2x">
        </body></html>
      ''';
      final paths = extractAssetPaths(html, serverOrigin: 'https://s.example');
      expect(paths, containsAll(<String>[
        'static/epub/u1/base.jpg',
        'static/epub/u1/a.jpg',
        'static/epub/u1/b.jpg',
      ]));
    });
  });

  group('extractCssRefs', () {
    test('resolves relative urls against the css directory', () {
      const css = '''
        @font-face { src: url(fonts/Mincho.woff2) format("woff2"); }
        .epub-body { background-image: url("../img/bg.png"); }
        .cover { background: url("/static/epub/u1/cover/abs.jpg"); }
        .data { background: url(data:image/png;base64,xx); }
        @import "extra/more.css";
      ''';
      final refs = extractCssRefs(css, 'static/epub/u1/lute.css');
      expect(refs, containsAll(<String>[
        'static/epub/u1/fonts/Mincho.woff2',
        // "../img/bg.png" climbs out of the css's own directory.
        'static/epub/img/bg.png',
        'static/epub/u1/cover/abs.jpg',
        'static/epub/u1/extra/more.css',
      ]));
      expect(refs.any((r) => r.contains('data:')), isFalse);
    });

    test('refs escaping the root are dropped', () {
      const css = 'a { background: url("../../../../etc/passwd"); }';
      expect(extractCssRefs(css, 'static/epub/u1/lute.css'), isEmpty);
    });
  });

  group('extractReadingBatches', () {
    test('words only, grouped per paragraph, with the page language id', () {
      final result = extractReadingBatches(samplePage);
      expect(result, isNotNull);
      expect(result!.langId, 9);
      // Paragraph 0: hello (12). Paragraph 1: 猫 (13), が (14).
      // Paragraph 2: 犬 (15). Non-words (wid 0) never appear.
      expect(result.batches, [
        ['hello'],
        ['猫', 'が'],
        ['犬'],
      ]);
    });

    test('null without a tokens node or a language id', () {
      expect(extractReadingBatches('<html><body>x</body></html>'), isNull);
      const noLang = '''
        <html><body>
        <script type="application/json" id="lute-epub-tokens">[["a",1,0,0,0]]</script>
        </body></html>
      ''';
      expect(extractReadingBatches(noLang), isNull);
    });
  });
}
