import 'dart:convert';

/// One action in the end-of-chapter block: the label the page prints and,
/// when known, the chapter number it leads to (`11 / 55`).
class ChapterNavTarget {
  const ChapterNavTarget({required this.label, this.sub});

  final String label;
  final String? sub;

  Map<String, dynamic> toJson() => {
    'label': label,
    if (sub != null && sub!.isNotEmpty) 'sub': sub,
  };
}

/// What the injected end-of-chapter block should say.
///
/// The block lives *inside the page* (appended after the chapter markup), so
/// it scrolls with the text instead of eating a strip off the bottom of the
/// screen -- on an e-ink phone the reading area is the scarce resource.
/// The app owns the labels (they come from l10n) and the page owns nothing:
/// [EpubChapterView] hands this down to the page as JSON.
class ChapterNavConfig {
  const ChapterNavConfig({
    required this.look,
    required this.endLabel,
    this.prev,
    this.next,
    this.contents = '',
  });

  /// 'original' / 'night' / 'theme'.  Decides the ink colour: the two paper
  /// looks pin the light palette and let the page's filter invert it, while
  /// the theme look reads the theme's own `--font-color`.
  final String look;

  /// `End of chapter`, or `End of book` on the last one.
  final String endLabel;

  final ChapterNavTarget? prev;
  final ChapterNavTarget? next;

  /// Label of the Contents row; empty when the set has no chapter list.
  final String contents;

  bool get isEmpty => prev == null && next == null && contents.isEmpty;

  Map<String, dynamic> toJson() => {
    'look': look,
    'end': endLabel,
    if (prev != null) 'prev': prev!.toJson(),
    if (next != null) 'next': next!.toJson(),
    if (contents.isNotEmpty) 'contents': contents,
  };

  /// Identity for the "did anything change" check between rebuilds.
  String get signature => jsonEncode(toJson());
}
