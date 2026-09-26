import 'package:html/parser.dart' as html_parser;
import 'dart:convert';
import 'package:html/dom.dart' as html;
import '../../core/logger/api_logger.dart';
import '../../features/reader/models/text_item.dart';
import '../../features/reader/models/paragraph.dart';
import '../../features/reader/models/page_data.dart';
import '../../features/reader/models/manga_page.dart';
import '../../features/reader/models/youtube_data.dart';
import '../../features/reader/models/term_tooltip.dart';
import '../../features/reader/models/term_form.dart';
import '../../shared/models/language.dart';
import '../../shared/models/language_card_settings.dart';
import '../../features/terms/models/term.dart';
import 'dictionary_service.dart';

class HtmlParser {
  final Function(String, int)? searchTermsProvider;

  HtmlParser({this.searchTermsProvider});

  PageData parsePage(
    String pageTextHtml,
    String pageMetadataHtml, {
    required int bookId,
  }) {
    final metadataDocument = html_parser.parse(pageMetadataHtml);
    final textDocument = html_parser.parse(pageTextHtml);

    final title = _extractTitle(metadataDocument);
    final currentPage = _extractCurrentPage(metadataDocument);
    final pageCount = _extractPageCount(metadataDocument);
    final paragraphs = _extractParagraphs(textDocument);
    final audioFilename = _extractAudioFilename(metadataDocument);
    final audioCurrentPos = _extractAudioCurrentPos(
      metadataDocument,
      textDocument,
    );
    final audioBookmarks = _extractAudioBookmarks(
      metadataDocument,
      textDocument,
    );
    final mangaPage = _extractManga(textDocument, currentPage);
    // The LUTE_YT_DATA block (YouTube videoId + MP3 audioUrl) is part of
    // the page body (the youtube/audio player include), which can arrive in
    // the text or the metadata document depending on endpoint.  The bilibili
    // include renders into the same block (bilibiliUrl/mpdUrl), so it is
    // searched the same way.
    final youtube =
        _extractYoutubeData(metadataDocument) ?? _extractYoutubeData(textDocument);
    final bilibili =
        _extractBilibiliData(metadataDocument) ??
        _extractBilibiliData(textDocument);
    final audioUrl =
        _extractAudioUrl(metadataDocument) ?? _extractAudioUrl(textDocument);
    // The players that drive the reading text's "line being played" mark all
    // read from cues, so they are gathered regardless of which backend the
    // book uses: an MP3 book emits the same block as a YouTube one, with a
    // null videoId (which is why _extractYoutubeData returns null for it).
    final cues = _extractCueList(metadataDocument, textDocument);
    final pageCueMap = _extractPageCueMapFrom(textDocument, metadataDocument);

    return PageData(
      bookId: bookId,
      currentPage: currentPage,
      pageCount: pageCount,
      title: title,
      paragraphs: paragraphs,
      audioFilename: audioFilename,
      audioUrl: audioUrl,
      audioCurrentPos: audioCurrentPos,
      audioBookmarks: audioBookmarks,
      mangaPage: mangaPage,
      youtube: youtube,
      bilibili: bilibili,
      cues: cues,
      pageCueMap: pageCueMap,
    );
  }

  String? _extractTitle(html.Document document) {
    final titleElement = document.querySelector('#thetexttitle');
    return titleElement?.text.trim();
  }

  int _extractPageCount(html.Document document) {
    final pageCountInput = document.querySelector('#page_count');
    if (pageCountInput != null) {
      final value = pageCountInput.attributes['value'];
      return value != null ? int.tryParse(value) ?? 1 : 1;
    }
    return 1;
  }

  int _extractCurrentPage(html.Document document) {
    final pageInput = document.querySelector('#page_num');
    if (pageInput != null) {
      final value = pageInput.attributes['value'];
      return int.tryParse(value ?? '') ?? 1;
    }
    return 1;
  }

  List<Paragraph> _extractParagraphs(html.Document document) {
    final theTextDiv = document.querySelector('#thetext');

    final paragraphs = <Paragraph>[];
    final sentences =
        theTextDiv?.querySelectorAll('.textsentence') ??
        document.querySelectorAll('.textsentence');

    for (var i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      final textItems = _extractTextItems(sentence);

      if (textItems.isNotEmpty) {
        paragraphs.add(Paragraph(id: i, textItems: textItems));
      }
    }

    return paragraphs;
  }

  List<TextItem> _extractTextItems(html.Element sentenceElement) {
    final textItems = <TextItem>[];
    final spans = sentenceElement.querySelectorAll('span');

    for (final span in spans) {
      final dataText = span.attributes['data-text'];
      if (dataText == null) continue;

      final statusClass = span.attributes['data-status-class'] ?? 'status0';
      final wordIdStr = span.attributes['data-wid'];
      final wordId = wordIdStr != null ? int.tryParse(wordIdStr) : null;
      final sentenceId = _extractIntAttribute(span, 'data-sentence-id') ?? 0;
      final paragraphId = _extractIntAttribute(span, 'data-paragraph-id') ?? 0;
      final order = _extractIntAttribute(span, 'data-order') ?? 0;
      final langId = _extractIntAttribute(span, 'data-lang-id');
      final classes = span.classes;
      final isStartOfSentence = classes.contains('sentencestart');

      textItems.add(
        TextItem(
          text: dataText,
          statusClass: statusClass,
          wordId: wordId,
          sentenceId: sentenceId,
          paragraphId: paragraphId,
          isStartOfSentence: isStartOfSentence,
          order: order,
          langId: langId,
        ),
      );
    }

    return textItems;
  }

  int? _extractIntAttribute(html.Element element, String attributeName) {
    final value = element.attributes[attributeName];
    return value != null ? int.tryParse(value) : null;
  }

  /// Extracts a Mokuro manga page (image + text blocks) from the page
  /// HTML served by the web app (`manga_page.html` template).  Returns
  /// null when the page is a regular text page.
  MangaPageData? _extractManga(html.Document document, int pageNum) {
    final mangaPageEl = document.querySelector('.manga-page');
    if (mangaPageEl == null) return null;

    final imgEl = mangaPageEl.querySelector('.manga-page-img');
    final imagePath = imgEl?.attributes['src'] ?? '';

    final imgWidth =
        double.tryParse(mangaPageEl.attributes['data-page-width'] ?? '') ?? 100;
    final imgHeight =
        double.tryParse(mangaPageEl.attributes['data-page-height'] ?? '') ??
        100;

    final blocks = <MangaBlock>[];
    final blockEls = mangaPageEl.querySelectorAll('.manga-text-block');
    for (final blockEl in blockEls) {
      final style = blockEl.attributes['style'] ?? '';
      final vertical = blockEl.classes.contains('manga-vertical');

      final lineItems = <List<TextItem>>[];
      final lineEls = blockEl.querySelectorAll('.manga-text-line');
      for (final lineEl in lineEls) {
        final items = _extractTextItems(lineEl);
        if (items.isNotEmpty) {
          lineItems.add(items);
        }
      }

      // The server template puts the font-size (in cqw) on the
      // .manga-text-line element, not on the block element.
      double fontSizeCqw = 0;
      final firstLineEl = blockEl.querySelector('.manga-text-line');
      if (firstLineEl != null) {
        fontSizeCqw = _extractCqw(firstLineEl.attributes['style'] ?? '');
      }

      blocks.add(
        MangaBlock(
          left: _extractPercent(style, 'left'),
          top: _extractPercent(style, 'top'),
          width: _extractPercent(style, 'width'),
          height: _extractPercent(style, 'height'),
          vertical: vertical,
          fontSizeCqw: fontSizeCqw,
          lineItems: lineItems,
        ),
      );
    }

    return MangaPageData(
      imagePath: imagePath,
      imgWidth: imgWidth,
      imgHeight: imgHeight,
      pageNum: pageNum,
      blocks: blocks,
    );
  }

  double _extractPercent(String style, String property) {
    final match = RegExp('$property\\s*:\\s*([0-9.]+)%').firstMatch(style);
    return match != null ? double.tryParse(match.group(1)!) ?? 0 : 0;
  }

  double _extractCqw(String style) {
    final match = RegExp('font-size\\s*:\\s*([0-9.]+)cqw').firstMatch(style);
    return match != null ? double.tryParse(match.group(1)!) ?? 0 : 0;
  }

  /// Extracts YouTube video data from the page metadata.  The web player
  /// include (`youtube_player.html`) renders a `LUTE_YT_DATA` script block
  /// with `videoId` / `startPos` / `cues`; for non-youtube books (including
  /// mp3, which reuses the same include) `videoId` is `null` and we return
  /// null.
  YoutubeData? _extractYoutubeData(html.Document document) {
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      if (!text.contains('LUTE_YT_DATA.videoId')) continue;

      final videoMatch = RegExp(
        r'LUTE_YT_DATA\.videoId\s*=\s*("([^"]*)"|null)',
      ).firstMatch(text);
      final videoId = videoMatch?.group(2);
      if (videoId == null || videoId.isEmpty) return null;

      return YoutubeData(
        videoId: videoId,
        startPos: _extractStartPos(text),
        cues: _extractCues(text),
      );
    }
    return null;
  }

  /// Extracts Bilibili video data from the page metadata.  The bilibili
  /// player include (`bilibili_player.html`) renders a `LUTE_YT_DATA`
  /// block with `bilibiliUrl` (the official embed URL, absolute) and
  /// `mpdUrl` (our server-relative DASH manifest; `null` when the server
  /// could not build one and only the embed fallback is available).
  /// Returns null for non-bilibili books, where neither line is emitted.
  BilibiliData? _extractBilibiliData(html.Document document) {
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      if (!text.contains('LUTE_YT_DATA.bilibiliUrl') &&
          !text.contains('LUTE_YT_DATA.mpdUrl')) {
        continue;
      }

      final embedUrl = _readJsonString(text, r'LUTE_YT_DATA\.bilibiliUrl');
      final mpdUrl = _readJsonString(text, r'LUTE_YT_DATA\.mpdUrl');
      final hasEmbed = embedUrl != null && embedUrl.isNotEmpty;
      final hasMpd = mpdUrl != null && mpdUrl.isNotEmpty;
      // A bilibili block with neither URL is not playable at all.
      if (!hasEmbed && !hasMpd) return null;

      return BilibiliData(
        mpdUrl: hasMpd ? mpdUrl : null,
        embedUrl: hasEmbed ? embedUrl : null,
        startPos: _extractStartPos(text),
        cues: _extractCues(text),
      );
    }
    return null;
  }

  /// Reads a `LUTE_YT_DATA.<field> = "..."` assignment rendered through
  /// Jinja's `tojson`, returning the decoded string.  Handles the HTML-safe
  /// escaping Flask applies (`&` becomes `\u0026` in embed URLs) and a
  /// literal `null`.  [assignmentTarget] is the regex for the left-hand
  /// side, so the dot in `LUTE_YT_DATA` must be escaped by the caller.
  String? _readJsonString(String scriptText, String assignmentTarget) {
    final match = RegExp(
      assignmentTarget + r'''\s*=\s*("(?:[^"\\]|\\.)*"|null)''',
    ).firstMatch(scriptText);
    final literal = match?.group(1);
    if (literal == null || literal == 'null') return null;
    try {
      final value = jsonDecode(literal);
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Reads `LUTE_YT_DATA.startPos = <number>`; 0 when absent/unreadable.
  double _extractStartPos(String scriptText) {
    final match = RegExp(
      r'LUTE_YT_DATA\.startPos\s*=\s*([0-9.]+)',
    ).firstMatch(scriptText);
    if (match == null) return 0;
    return double.tryParse(match.group(1)!) ?? 0;
  }

  /// Reads the `LUTE_YT_DATA.cues = [...]` array out of a script block.
  ///
  /// The literal is raw JSON, so it is delimited by bracket balance rather
  /// than by a regex: cue text is arbitrary book content and may itself
  /// contain brackets, braces, quotes and commas.  Anything unreadable
  /// degrades to "no subtitles" -- the player still plays, just without
  /// per-sentence loop and auto-pause.
  static List<YoutubeCue> _extractCues(String scriptText) {
    const marker = 'LUTE_YT_DATA.cues';
    final markerIndex = scriptText.indexOf(marker);
    if (markerIndex < 0) return const [];

    final start = scriptText.indexOf('[', markerIndex + marker.length);
    if (start < 0) return const [];

    final end = _matchingBracket(scriptText, start);
    if (end < 0) return const [];

    try {
      return YoutubeCue.listFromJson(
        jsonDecode(scriptText.substring(start, end + 1)),
      );
    } catch (_) {
      return const [];
    }
  }

  /// The book's subtitle cues, whichever document carries the
  /// `LUTE_YT_DATA.cues` block.
  ///
  /// The block is part of the page body (the player include) and can arrive
  /// in the text or the metadata document depending on endpoint -- the same
  /// ambiguity [_extractYoutubeData] handles.  The first document that
  /// yields a non-empty list wins, so a book whose metadata block renders
  /// `[]` still gets its cues from the body.
  static List<YoutubeCue> _extractCueList(
    html.Document metadataDocument,
    html.Document textDocument,
  ) {
    for (final document in [metadataDocument, textDocument]) {
      for (final script in document.querySelectorAll('script')) {
        if (!script.text.contains('LUTE_YT_DATA.cues')) continue;
        final cues = _extractCues(script.text);
        if (cues.isNotEmpty) return cues;
      }
    }
    return const [];
  }

  /// Reads `window.LUTE_PAGE_CUE_MAP = [...]` -- the cue index of each line
  /// of this page, in line order.
  ///
  /// Empty for books without cues, for older servers that do not render the
  /// map, and for pages whose lines no longer match the cues.  Callers fall
  /// back to matching the cue text against the page's lines in that case.
  static List<int> _extractPageCueMap(html.Document document) {
    const marker = 'LUTE_PAGE_CUE_MAP';
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      final markerIndex = text.indexOf(marker);
      if (markerIndex < 0) continue;

      final start = text.indexOf('[', markerIndex + marker.length);
      if (start < 0) continue;

      final end = _matchingBracket(text, start);
      if (end < 0) continue;

      try {
        final decoded = jsonDecode(text.substring(start, end + 1));
        if (decoded is! List) continue;
        return decoded
            .map(
              (value) =>
                  value is num ? value.toInt() : int.tryParse('$value'),
            )
            .whereType<int>()
            .toList();
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  /// The page's cue map, from whichever document carries it.  It is rendered
  /// with the page body (`read/page_content.html`), so the text document is
  /// tried first; the metadata document is a fallback for endpoints that
  /// inline the body.
  static List<int> _extractPageCueMapFrom(
    html.Document textDocument,
    html.Document metadataDocument,
  ) {
    final fromText = _extractPageCueMap(textDocument);
    return fromText.isNotEmpty
        ? fromText
        : _extractPageCueMap(metadataDocument);
  }

  /// Index of the `]` that closes the `[` at [openIndex], or -1 when the
  /// brackets never balance.  String literals and escapes are skipped so a
  /// cue text containing `]` or `"` cannot close the array early.
  static int _matchingBracket(String source, int openIndex) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = openIndex; i < source.length; i++) {
      final char = source[i];

      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == '\\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }

      if (char == '"') {
        inString = true;
      } else if (char == '[') {
        depth++;
      } else if (char == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Extracts the audio URL exposed by MP3 books via `LUTE_YT_DATA.audioUrl`.
  /// Regular audio books do not set this (they use `book_audio_file`), so it
  /// is normally null for them.  Returns a server-relative path like
  /// `/useraudio/stream/<id>` for MP3 books.
  String? _extractAudioUrl(html.Document document) {
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      if (!text.contains('LUTE_YT_DATA.audioUrl')) continue;
      final match = RegExp(
        r'LUTE_YT_DATA\.audioUrl\s*=\s*("([^"]*)"|null)',
      ).firstMatch(text);
      final url = match?.group(2);
      if (url == null || url.isEmpty) return null;
      return url;
    }
    return null;
  }

  TermTooltip parseTermTooltip(String htmlContent) {
    final document = html_parser.parse(htmlContent);

    final termElement = document.querySelector('b');
    final term = termElement?.text.trim() ?? '';

    final paragraphs = document.querySelectorAll('p');
    String? translation;
    if (paragraphs.length > 1) {
      final paragraph = paragraphs[1];
      ApiLogger.logLoading(
        'parsePageTranslation',
        details: 'innerHtml="${paragraph.innerHtml}"',
      );

      final innerHtml = paragraph.innerHtml;

      if (!innerHtml.contains('<br')) {
        translation = paragraph.text.trim();
      } else {
        final parts = innerHtml.split(
          RegExp(r'<br\s*/?>', caseSensitive: false),
        );
        final textParts = <String>[];

        for (final part in parts) {
          final tempElement = document.createElement('div');
          tempElement.innerHtml = part;
          final text = tempElement.text.trim();
          if (text.isNotEmpty) {
            textParts.add(text);
          }
        }

        translation = textParts.join(', ');
        ApiLogger.logLoading(
          'parsePageTranslation',
          details: 'splitParts=$textParts',
        );
      }

      ApiLogger.logLoading(
        'parsePageTranslation',
        details: 'finalTranslation="$translation"',
      );

      if (translation.isEmpty) {
        translation = null;
      }
    }

    final termIdInput = document.querySelector('input[name="termid"]');
    final termId = termIdInput != null
        ? int.tryParse(termIdInput.attributes['value'] ?? '')
        : null;

    final statusInput = document.querySelector('select[name="status"]');
    String status = '99';
    if (statusInput != null) {
      final selectedOption = statusInput.querySelector('option[selected]');
      status = selectedOption?.attributes['value'] ?? '99';
    }

    final sentences = <String>[];
    final sentenceElements = document.querySelectorAll(
      '.term-popup .sentences li',
    );
    for (final sentenceElement in sentenceElements) {
      final sentence = sentenceElement.text.trim();
      if (sentence.isNotEmpty) {
        sentences.add(sentence);
      }
    }

    final langIdInput = document.querySelector('input[name="langid"]');
    final languageId = langIdInput != null
        ? int.tryParse(langIdInput.attributes['value'] ?? '')
        : null;

    final imageElement =
        document.querySelector('.term-popup img[src*="/userimages/"]') ??
        document.querySelector('.term-popup img[src*="userimages/"]') ??
        document.querySelector('img[src*="/userimages/"]') ??
        document.querySelector('img[src*="userimages/"]');
    String? imageUrl = imageElement?.attributes['src']?.trim();
    if (imageUrl?.isEmpty == true) {
      imageUrl = null;
    }

    String? imageFilename;
    if (imageUrl != null) {
      try {
        final uri = Uri.parse(imageUrl);
        if (uri.pathSegments.isNotEmpty) {
          imageFilename = uri.pathSegments.last;
        }
      } catch (_) {
        final segments = imageUrl.split('/');
        if (segments.isNotEmpty) {
          imageFilename = segments.last;
        }
      }
    }

    final parents = <TermParent>[];

    final parentElements = document.querySelectorAll('.term-popup .parents li');

    for (final parentElement in parentElements) {
      final link = parentElement.querySelector('a');
      if (link != null) {
        final href = link.attributes['href'];
        int? parentId;
        if (href != null) {
          final idMatch = RegExp(r'/term/(\d+)').firstMatch(href);
          if (idMatch != null) {
            parentId = int.tryParse(idMatch.group(1) ?? '');
          }
        }

        String parentTerm = link.text.trim();
        String? parentTranslation;

        final translationSpan = parentElement.querySelector(
          '.translation, span.translation, .tr',
        );
        if (translationSpan != null) {
          final innerHtml = translationSpan.innerHtml;

          if (!innerHtml.contains('<br')) {
            parentTranslation = translationSpan.text.trim();
          } else {
            final parts = innerHtml.split(
              RegExp(r'<br\s*/?>', caseSensitive: false),
            );
            final textParts = <String>[];

            for (final part in parts) {
              final tempElement = document.createElement('div');
              tempElement.innerHtml = part;
              final text = tempElement.text.trim();
              if (text.isNotEmpty) {
                textParts.add(text);
              }
            }

            parentTranslation = textParts.join(', ');
            ApiLogger.logLoading(
              'parseTermParents',
              details: 'parentTranslationParts=$textParts',
            );
          }

          if (parentTranslation.isEmpty) {
            parentTranslation = null;
          }
        }

        if (parentTerm.isNotEmpty) {
          parents.add(
            TermParent(
              id: parentId,
              term: parentTerm,
              translation: parentTranslation,
            ),
          );
        }
      } else {
        final parentTerm = parentElement.text.trim();
        if (parentTerm.isNotEmpty) {
          parents.add(TermParent(id: null, term: parentTerm));
        }
      }
    }

    if (parents.isEmpty) {
      final allDivs = document.querySelectorAll('div');
      for (final div in allDivs) {
        final styleAttr = div.attributes['style'];
        if (styleAttr != null && styleAttr.contains('margin-top: 1.5em')) {
          final pElements = div.querySelectorAll('p');
          for (final pElement in pElements) {
            final boldElement = pElement.querySelector('b');
            if (boldElement != null) {
              final parentTerm = boldElement.text.trim();
              String? parentTranslation;

              final innerHtml = pElement.innerHtml;

              if (!innerHtml.contains('<br')) {
                parentTranslation = pElement.text
                    .split(parentTerm)
                    .skip(1)
                    .join('')
                    .trim();
                if (parentTranslation.isEmpty) {
                  parentTranslation = null;
                }
              } else {
                final parts = innerHtml.split(
                  RegExp(r'<br\s*/?>', caseSensitive: false),
                );
                final textParts = <String>[];

                for (final part in parts) {
                  final tempElement = document.createElement('div');
                  tempElement.innerHtml = part;
                  final text = tempElement.text.trim();
                  if (text.isNotEmpty && text != parentTerm) {
                    textParts.add(text);
                  }
                }

                parentTranslation = textParts.join(', ');
                ApiLogger.logLoading(
                  'parseTermParents',
                  details: 'fallbackTranslationParts=$textParts',
                );
              }

              if (parentTerm.isNotEmpty) {
                parents.add(
                  TermParent(
                    id: null,
                    term: parentTerm,
                    translation: parentTranslation,
                  ),
                );
              }
            }
          }
          break;
        }
      }
    }

    final children = <TermChild>[];
    final childElements = document.querySelectorAll('.term-popup .children li');
    for (final childElement in childElements) {
      final childTerm = childElement.text.trim();
      if (childTerm.isNotEmpty) {
        children.add(TermChild(term: childTerm));
      }
    }

    return TermTooltip(
      term: term,
      translation: translation,
      termId: termId,
      status: status,
      sentences: sentences,
      languageId: languageId,
      imageUrl: imageUrl,
      imageFilename: imageFilename,
      parents: parents,
      children: children,
    );
  }

  TermForm parseTermForm(String htmlContent, {int? termId}) {
    final document = html_parser.parse(htmlContent);

    final termInput = document.querySelector('input[name="text"]');
    final term = termInput?.attributes['value']?.trim() ?? '';

    final translationTextarea = document.querySelector(
      'textarea[name="translation"]',
    );
    final translation = translationTextarea?.text.trim();

    final termIdInput = document.querySelector('input[name="termid"]');
    final termIdValue = termIdInput?.attributes['value'] ?? '';
    ApiLogger.logLoading(
      'parseTermForm',
      details:
          'term="$term", termIdInput="$termIdValue", providedTermId=$termId',
    );
    final parsedTermId = termIdInput != null
        ? int.tryParse(termIdValue)
        : termId;
    ApiLogger.logLoading('parseTermForm', details: 'finalTermId=$parsedTermId');

    final langIdInput = document.querySelector('select[name="language_id"]');
    final languageId = langIdInput != null
        ? (int.tryParse(
                langIdInput
                        .querySelector('option[selected]')
                        ?.attributes['value'] ??
                    '',
              ) ??
              0)
        : 0;

    String status = '99';
    final statusRadioInputs = document.querySelectorAll(
      'input[name="status"][type="radio"]',
    );
    for (final radio in statusRadioInputs) {
      if (radio.attributes['checked'] != null) {
        status = radio.attributes['value'] ?? '99';
        break;
      }
    }

    final tagsInput = document.querySelector('input[name="termtagslist"]');
    String? tags = tagsInput?.attributes['value']?.trim();
    List<String>? tagList;
    if (tags?.isNotEmpty == true) {
      try {
        final decoded = Uri.decodeComponent(tags!);
        final jsonList = jsonDecode(decoded) as List;
        tagList = jsonList
            .map((item) => item['value'] as String?)
            .where((value) => value != null && value.isNotEmpty)
            .cast<String>()
            .toList();
        if (tagList.isEmpty) {
          tagList = null;
        }
      } catch (e) {
        ApiLogger.logError('parseTermForm tags', e);
        tagList = null;
      }
    }

    final romanizationInput = document.querySelector(
      'input[name="romanization"]',
    );
    final romanization = romanizationInput?.attributes['value']?.trim();

    final currentImageInput = document.querySelector(
      'input[name="current_image"]',
    );
    String? imageFilename = currentImageInput?.attributes['value']?.trim();
    if (imageFilename == null ||
        imageFilename.isEmpty ||
        imageFilename == '-') {
      imageFilename = null;
    }

    final imageElement =
        document.querySelector('#term_image') ??
        document.querySelector('img[src*="/userimages/"]') ??
        document.querySelector('img[src*="userimages/"]');
    String? imageUrl = imageElement?.attributes['src']?.trim();
    if (imageUrl?.isEmpty == true || imageUrl?.endsWith('/-') == true) {
      imageUrl = null;
    }

    if (imageUrl == null && imageFilename != null) {
      imageUrl = '/userimages/$languageId/$imageFilename';
    }

    if (imageFilename == null && imageUrl != null) {
      try {
        final uri = Uri.parse(imageUrl);
        if (uri.pathSegments.isNotEmpty) {
          final lastSegment = uri.pathSegments.last;
          if (lastSegment.isNotEmpty && lastSegment != '-') {
            imageFilename = lastSegment;
          }
        }
      } catch (_) {
        final segments = imageUrl.split('/');
        if (segments.isNotEmpty) {
          final lastSegment = segments.last;
          if (lastSegment.isNotEmpty && lastSegment != '-') {
            imageFilename = lastSegment;
          }
        }
      }
    }

    final romanizationParent = romanizationInput?.parent;
    bool showRomanization = true;
    if (romanizationParent is html.Element) {
      final displayStyle = romanizationParent.attributes['style'];
      showRomanization = displayStyle?.contains('display:none;') != true;
    }

    final syncStatusInput = document.querySelector('input[name="sync_status"]');
    final hasCheckedAttr = syncStatusInput?.attributes.containsKey('checked');
    bool? syncStatus = hasCheckedAttr ?? false;

    final dictionaries = <String>[];
    final dictElements = document.querySelectorAll('.dictionary-list li');
    for (final dictElement in dictElements) {
      final dict = dictElement.text.trim();
      if (dict.isNotEmpty) {
        dictionaries.add(dict);
      }
    }

    final parents = <TermParent>[];
    final parentsListInput = document.querySelector(
      'input[name="parentslist"]',
    );
    if (parentsListInput != null) {
      final parentsListValue = parentsListInput.attributes['value'];
      ApiLogger.logLoading(
        'parseTermForm',
        details: 'parentsListValue="$parentsListValue"',
      );
      if (parentsListValue != null && parentsListValue.isNotEmpty) {
        try {
          final decoded = Uri.decodeComponent(parentsListValue);
          ApiLogger.logLoading(
            'parseTermForm',
            details: 'decodedParentsList="$decoded"',
          );
          final jsonList = jsonDecode(decoded) as List;
          for (final item in jsonList) {
            final parentData = item as Map<String, dynamic>;
            final parentTerm = parentData['value'] as String?;
            ApiLogger.logLoading(
              'parseTermForm',
              details: 'parentData=$parentData',
            );
            if (parentTerm != null && parentTerm.isNotEmpty) {
              parents.add(
                TermParent(
                  id: null,
                  term: parentTerm,
                  translation: null,
                  status: parentData['status'] as int?,
                  syncStatus: parentData['sync_status'] as bool?,
                ),
              );
            }
          }
          ApiLogger.logLoading(
            'parseTermForm',
            details: 'parsedParentsCount=${parents.length}',
          );
        } catch (e) {
          ApiLogger.logError('parseTermParents', e);
        }
      }
    }

    return TermForm(
      term: term,
      translation: translation,
      termId: parsedTermId,
      languageId: languageId,
      status: status,
      tags: tagList,
      romanization: romanization,
      imageUrl: imageUrl,
      imageFilename: imageFilename,
      showRomanization: showRomanization,
      dictionaries: dictionaries,
      parents: parents,
      syncStatus: syncStatus,
    );
  }

  List<String> parseLanguages(String htmlContent) {
    final document = html_parser.parse(htmlContent);

    final languageLinks = document.querySelectorAll(
      'table tbody tr a[href^="/language/edit/"]',
    );

    return languageLinks
        .map((link) => link.text.trim())
        .where((lang) => lang.isNotEmpty)
        .toList();
  }

  List<Language> parseLanguagesWithIds(String htmlContent) {
    final document = html_parser.parse(htmlContent);

    // 逐行解析而不是只抓 <a>：Song 的语言页（/language/index）每行有
    // 状态列 '● Active' / '● Frozen'，冻结语言要从行文本里识别出来，
    // 对齐 web 端语言过滤下拉排除冻结语言的行为。
    final rows = document.querySelectorAll('table tbody tr');

    final parsedLanguages = <Language>[];
    for (final row in rows) {
      final link = row.querySelector('a[href^="/language/edit/"]');
      if (link == null) continue;

      final href = link.attributes['href'] ?? '';
      final idMatch = RegExp(r'/language/edit/(\d+)').firstMatch(href);
      final id = idMatch != null
          ? int.tryParse(idMatch.group(1) ?? '')
          : null;
      final name = link.text.trim();
      if (id == null || name.isEmpty) continue;

      // 旧版语言页没有 Frozen 状态列，row.text 不含 'Frozen'，默认全部 active。
      final isActive = !row.text.contains('Frozen');
      parsedLanguages.add(Language(id: id, name: name, isActive: isActive));
    }

    // Keep only one entry per ID to avoid invalid dropdown states when
    // upstream HTML contains duplicate language links.
    final uniqueById = <int, Language>{};
    for (final language in parsedLanguages) {
      uniqueById.putIfAbsent(language.id, () => language);
    }
    return uniqueById.values.toList();
  }

  LanguageCardSettings parseLanguageCardSettings(
    String htmlContent,
    int languageId,
  ) {
    final document = html_parser.parse(htmlContent);

    final name =
        document.querySelector('#name')?.attributes['value']?.trim() ?? '';
    final showRomanization =
        document.querySelector('#show_romanization')?.attributes['checked'] !=
        null;
    final rightToLeft =
        document.querySelector('#right_to_left')?.attributes['checked'] != null;

    final parserOptions = document
        .querySelectorAll('#parser_type option')
        .map((option) => option.attributes['value']?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();

    final selectedParser = _getSelectedOptionValue(
      document.querySelector('#parser_type'),
    );
    final parserType =
        selectedParser ??
        (parserOptions.isNotEmpty ? parserOptions.first : 'spacedel');

    final characterSubstitutions =
        document
            .querySelector('#character_substitutions')
            ?.attributes['value']
            ?.trim() ??
        '';
    final regexpSplitSentences =
        document
            .querySelector('#regexp_split_sentences')
            ?.attributes['value']
            ?.trim() ??
        '';
    final exceptionsSplitSentences =
        document
            .querySelector('#exceptions_split_sentences')
            ?.attributes['value']
            ?.trim() ??
        '';
    final wordCharacters =
        document
            .querySelector('#word_characters')
            ?.attributes['value']
            ?.trim() ??
        '';

    final dictionaries = document
        .querySelectorAll('.dict_entry')
        .map((entry) {
          final uriInput = entry.querySelector('input[name*="dicturi"]');
          if (uriInput == null) return null;

          final uri = uriInput.attributes['value']?.trim() ?? '';
          if (uri.isEmpty || uri == '__TEMPLATE__') return null;

          final useFor =
              _getSelectedOptionValue(
                entry.querySelector('select.dict-usefor'),
              ) ??
              'terms';
          final dictType =
              _getSelectedOptionValue(
                entry.querySelector('select.dict-type'),
              ) ??
              'embeddedhtml';
          final isActive =
              entry
                  .querySelector('input[name*="is_active"]')
                  ?.attributes['checked'] !=
              null;
          final sortOrder = int.tryParse(
            entry
                    .querySelector('input[name*="sort_order"]')
                    ?.attributes['value'] ??
                '',
          );

          return LanguageDictionarySetting(
            useFor: useFor,
            dictType: dictType,
            dictUri: uri,
            isActive: isActive,
            sortOrder: sortOrder ?? 0,
          );
        })
        .whereType<LanguageDictionarySetting>()
        .toList();

    return LanguageCardSettings(
      languageId: languageId,
      name: name,
      showRomanization: showRomanization,
      rightToLeft: rightToLeft,
      parserType: parserType,
      parserTypeOptions: parserOptions,
      characterSubstitutions: characterSubstitutions,
      regexpSplitSentences: regexpSplitSentences,
      exceptionsSplitSentences: exceptionsSplitSentences,
      wordCharacters: wordCharacters,
      dictionaries: dictionaries,
    );
  }

  String? _getSelectedOptionValue(html.Element? selectElement) {
    if (selectElement == null) return null;
    final options = selectElement.querySelectorAll('option');
    for (final option in options) {
      if (option.attributes.containsKey('selected')) {
        return option.attributes['value']?.trim();
      }
    }
    if (options.isEmpty) return null;
    return options.first.attributes['value']?.trim();
  }

  List<String> parsePredefinedLanguageNames(String htmlContent) {
    final document = html_parser.parse(htmlContent);
    return document
        .querySelectorAll('#predefined option')
        .map((option) => option.attributes['value']?.trim() ?? '')
        .where((value) => value.isNotEmpty && value != '-')
        .toList();
  }

  List<DictionarySource> parseLanguageDictionaries(String htmlContent) {
    final document = html_parser.parse(htmlContent);
    final dictionaries = <DictionarySource>[];

    final dictEntries = document.querySelectorAll('.dict_entry');
    for (final entry in dictEntries) {
      final uriInput = entry.querySelector('input[name*="dicturi"]');
      final useforSelect = entry.querySelector('select[name*="usefor"]');
      final isActiveCheckbox = entry.querySelector('input[name*="is_active"]');

      if (uriInput == null) continue;

      final uri = uriInput.attributes['value']?.trim() ?? '';
      if (uri.isEmpty || uri == '__TEMPLATE__') continue;

      final usefor =
          useforSelect
              ?.querySelector('option[selected]')
              ?.attributes['value'] ??
          '';
      final isActive = isActiveCheckbox?.attributes['checked'] != null;

      if (!isActive) continue;
      if (usefor != 'terms') continue;

      String displayName = _extractDictionaryName(uri);

      dictionaries.add(DictionarySource(name: displayName, urlTemplate: uri));
    }

    return dictionaries;
  }

  List<DictionarySource> parseSentenceDictionaries(String htmlContent) {
    final document = html_parser.parse(htmlContent);
    final dictionaries = <DictionarySource>[];

    final dictEntries = document.querySelectorAll('.dict_entry');
    for (final entry in dictEntries) {
      final uriInput = entry.querySelector('input[name*="dicturi"]');
      final useforSelect = entry.querySelector('select[name*="usefor"]');
      final isActiveCheckbox = entry.querySelector('input[name*="is_active"]');

      if (uriInput == null) continue;

      final uri = uriInput.attributes['value']?.trim() ?? '';
      if (uri.isEmpty || uri == '__TEMPLATE__') continue;

      final usefor =
          useforSelect
              ?.querySelector('option[selected]')
              ?.attributes['value'] ??
          '';
      final isActive = isActiveCheckbox?.attributes['checked'] != null;

      if (!isActive) continue;
      if (usefor != 'sentences') continue;

      String displayName = _extractDictionaryName(uri);

      dictionaries.add(DictionarySource(name: displayName, urlTemplate: uri));
    }

    return dictionaries;
  }

  String _extractDictionaryName(String uri) {
    try {
      final uriLower = uri.toLowerCase();

      final uriParsed = Uri.parse(uri);
      final host = uriParsed.host.replaceAll('www.', '');

      final pathSegments = uriParsed.pathSegments
          .where((s) => s.isNotEmpty)
          .toList();

      if (uriLower.contains('wiktionary')) {
        final langMatch = RegExp(
          r'wiktionary\.org/w/index\.php\?search=\[LUTE\]#(\w+)',
        ).firstMatch(uriLower);
        if (langMatch != null && langMatch.group(1) != null) {
          return 'Wiktionary (${langMatch.group(1)!})';
        }
        return 'Wiktionary';
      }
      if (uriLower.contains('reverso')) {
        return 'Reverso';
      }
      if (uriLower.contains('deepl')) {
        return 'DeepL';
      }
      if (uriLower.contains('google.com/translator')) {
        return 'Google Translate';
      }
      if (uriLower.contains('translate.google')) {
        return 'Google Translate';
      }
      if (uriLower.contains('livingarabic')) {
        return 'Living Arabic';
      }
      if (uriLower.contains('arabicstudentsdictionary')) {
        return 'Arabic Students Dictionary';
      }
      if (pathSegments.isNotEmpty) {
        final lastSegment = pathSegments.last.toLowerCase();
        if (lastSegment == 'search' ||
            lastSegment == 'translate' ||
            lastSegment == 'w' ||
            lastSegment == 'wiki') {
          return host
              .split('.')
              .take(2)
              .map((s) => s[0].toUpperCase() + s.substring(1))
              .join('.');
        }
      }

      final cleanHost = host.split('.').take(2).join('.');
      final words = cleanHost.split('.');
      final formattedWords = words
          .map((w) => w[0].toUpperCase() + w.substring(1))
          .toList();
      if (formattedWords.length >= 2) {
        return formattedWords.join(' ');
      }
      return formattedWords.first;
    } catch (e) {
      return 'Dictionary';
    }
  }

  String? _extractAudioFilename(html.Document document) {
    final audioInput = document.querySelector('input[id="book_audio_file"]');
    final value = audioInput?.attributes['value']?.trim();
    ApiLogger.logLoading('_extractAudioFilename', details: 'found=$value');
    return value;
  }

  /// Where the MP3 player should resume, or null when the page carries no
  /// position at all.
  ///
  /// Two sources, tried in order:
  ///
  ///  1. `input#book_audio_current_pos` -- the hidden field rendered by the
  ///     *old* audio player.  Kept first so a server that still ships that
  ///     player keeps working.
  ///  2. `LUTE_YT_DATA.startPos` -- what the current server actually emits.
  ///     MP3 books reuse the video player include (`lute/templates/read/index.html`:
  ///     `{% if book.audio_filename %}{% include "read/youtube_player.html" %}`),
  ///     and that include renders `window.LUTE_YT_DATA.startPos = {{ video_current_pos }}`,
  ///     where the server folds the legacy column in
  ///     (`read/routes.py`: `video_current_pos=book.video_current_pos or book.audio_current_pos or 0`).
  ///
  /// Reading only source 1 silently returns null against this server -- the
  /// old player was removed, so the input no longer exists -- and the player
  /// then resumes at 00:00 on every open even though the position is saved
  /// correctly on every tick.  Verified on a Leaf5C against the live server:
  /// the row held `BkAudioCurrentPos = 191.814` while the UI showed
  /// `00:00 / 05:24`, both after backgrounding and after a cold start.
  ///
  /// [textDocument] is searched too because which endpoint delivers the
  /// player block varies (full `/read/<id>` vs the per-page partial), the same
  /// reason `_extractYoutubeData` is tried against both documents.
  Duration? _extractAudioCurrentPos(
    html.Document document, [
    html.Document? textDocument,
  ]) {
    final positionInput = document.querySelector(
      'input[id="book_audio_current_pos"]',
    );
    final positionStr = positionInput?.attributes['value']?.trim();
    if (positionStr != null && positionStr.isNotEmpty) {
      final position = double.tryParse(positionStr);
      if (position != null) {
        ApiLogger.logLoading(
          '_extractAudioCurrentPos',
          details: 'legacy input, ${position}s',
        );
        return _secondsToDuration(position);
      }
    }

    for (final candidate in <html.Document?>[document, textDocument]) {
      if (candidate == null) continue;
      final startPos = _findPlayerStartPos(candidate);
      if (startPos != null) {
        ApiLogger.logLoading(
          '_extractAudioCurrentPos',
          details: 'LUTE_YT_DATA.startPos, ${startPos}s',
        );
        return _secondsToDuration(startPos);
      }
    }
    return null;
  }

  /// Seconds (as the server stores them, a float) to a [Duration].  Keeps the
  /// fractional part: the save side posts `inMilliseconds / 1000.0`, so
  /// truncating here would throw away a resumed listener's place on every
  /// reopen.
  Duration _secondsToDuration(double seconds) =>
      Duration(milliseconds: (seconds * 1000).round());

  /// Reads `LUTE_YT_DATA.startPos` from whichever script block carries it,
  /// or null when no block does -- as opposed to a real `0`, which means
  /// "start at the beginning".  The distinction only matters for logging and
  /// for the load signature; both skip the seek.
  double? _findPlayerStartPos(html.Document document) {
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      if (!text.contains('LUTE_YT_DATA.startPos')) continue;
      return _extractStartPos(text);
    }
    return null;
  }

  /// The bookmarks the server holds for this book, or null when the page
  /// carried no bookmark data at all.
  ///
  /// Two sources, tried in order -- the same pair as [_extractAudioCurrentPos]:
  ///
  ///  1. `input#book_audio_bookmarks` -- the hidden field the *old* audio
  ///     player rendered (kept first so a server that still ships it keeps
  ///     working).  Its value is authoritative even when empty.
  ///  2. `LUTE_YT_DATA.bookmarks` -- what the current server emits
  ///     (`read/youtube_player.html`), as the semicolon-separated seconds
  ///     string the column stores.
  ///
  /// **null and `[]` mean different things, and the difference is load
  /// bearing.** `[]` is "the server says this book has no bookmarks"; null is
  /// "this page did not tell us".  Only the former may be written back -- see
  /// `_savePosition` in `audio_player_provider.dart`.  Collapsing the two is
  /// how every bookmark in the library got wiped: the app posted an empty
  /// list over the stored one every 2 s (measured on a Leaf5C:
  /// `BkAudioBookmarks` went `86.989` -> NULL on a plain reopen).
  List<double>? _extractAudioBookmarks(
    html.Document document, [
    html.Document? textDocument,
  ]) {
    final bookmarksInput =
        document.querySelector('input[id="book_audio_bookmarks"]') ??
        document.querySelector('input[name="audio_bookmarks"]');
    final bookmarksStr = bookmarksInput?.attributes['value']?.trim();
    if (bookmarksStr != null) {
      ApiLogger.logLoading(
        '_extractAudioBookmarks',
        details: 'legacy input, ${bookmarksStr.length} chars',
      );
      return _parseBookmarkList(bookmarksStr);
    }

    for (final candidate in <html.Document?>[document, textDocument]) {
      if (candidate == null) continue;
      final raw = _findPlayerBookmarks(candidate);
      if (raw != null) {
        ApiLogger.logLoading(
          '_extractAudioBookmarks',
          details: 'LUTE_YT_DATA.bookmarks, ${raw.length} chars',
        );
        return _parseBookmarkList(raw);
      }
    }
    return null;
  }

  /// Reads the `LUTE_YT_DATA.bookmarks` literal out of whichever script block
  /// carries it.
  ///
  /// The server renders it through `tojson`, so it is always a quoted JS
  /// string -- `""` when the book has no bookmarks.  Returns null when the
  /// assignment is absent, which is deliberately **not** the same as `""`;
  /// [_readJsonString] cannot be reused here because it folds both to null.
  String? _findPlayerBookmarks(html.Document document) {
    for (final script in document.querySelectorAll('script')) {
      final text = script.text;
      if (!text.contains('LUTE_YT_DATA.bookmarks')) continue;
      final match = RegExp(
        r'LUTE_YT_DATA\.bookmarks\s*=\s*("(?:[^"\\]|\\.)*")',
      ).firstMatch(text);
      if (match == null) continue;
      try {
        final value = jsonDecode(match.group(1)!);
        return value is String ? value : '';
      } catch (_) {
        return '';
      }
    }
    return null;
  }

  /// Parses a bookmark payload in either shape the server has used: a JSON
  /// array, or the semicolon-separated seconds string the mobile client posts
  /// (`bookmarks.map((b) => b.toString()).join(';')`).  Anything unparseable
  /// degrades to "no bookmarks" rather than throwing -- a malformed list must
  /// not take the player down with it.
  List<double> _parseBookmarkList(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return decoded.whereType<num>().map((b) => b.toDouble()).toList();
      }
    } catch (_) {
      // Not JSON -- fall through to the semicolon form.
    }
    return trimmed
        .split(';')
        .map((s) => double.tryParse(s.trim()))
        .whereType<double>()
        .toList();
  }

  List<Term> parseTermsFromDatatables(String jsonData) {
    try {
      final decoded = jsonDecode(jsonData) as Map<String, dynamic>;
      final data = decoded['data'] as List;

      ApiLogger.logLoading(
        'parseTermsFromDatatables',
        details: 'received ${data.length} terms',
      );

      if (data.isNotEmpty) {
        final firstTermLang = data[0]['LgName'];
        final uniqueLangs = data.map((t) => t['LgName']).toSet();
        ApiLogger.logLoading(
          'parseTermsFromDatatables',
          details: 'uniqueLanguages=$uniqueLangs',
        );
        ApiLogger.logLoading(
          'parseTermsFromDatatables',
          details: 'firstTermLanguage=$firstTermLang',
        );
      }

      return data.map((item) {
        final termData = item as Map<String, dynamic>;
        return Term.fromJson(termData);
      }).toList();
    } catch (e) {
      ApiLogger.logError('parseTermsFromDatatables', e);
      return [];
    }
  }
}
