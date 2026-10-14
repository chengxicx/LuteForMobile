// Layout contract for the reader's furigana rendering.
//
// The reading page lays every word out as its own cell inside a `Wrap`, so
// the cells' heights are independent.  If only the *annotated* words got a
// reading slot, an annotated cell would be taller than its neighbours and
// the kanji/kana baselines the forced strut works so hard to align would
// drift apart again.  Hence the contract asserted here: when furigana is on,
// **every** word cell reserves the same slot -- including words the server
// gave no reading for, and including the window before the readings have
// arrived (the web reader reserves the space the same way, by adding its
// `furigana-on` class before the readings land).
//
// 运行：flutter test test/furigana_render_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/reader/models/paragraph.dart';
import 'package:song_mobile/features/reader/models/text_item.dart';
import 'package:song_mobile/features/reader/widgets/text_display.dart';

TextItem _item(String text, {int? wordId, int order = 0}) => TextItem(
  text: text,
  statusClass: 'status0',
  wordId: wordId,
  sentenceId: 0,
  paragraphId: 0,
  isStartOfSentence: order == 0,
  order: order,
);

/// One line of two words: 夜 has a reading, の does not.
List<Paragraph> _paragraphs() => [
  Paragraph(
    id: 0,
    textItems: [
      _item('夜', wordId: 1, order: 0),
      _item('の', wordId: 2, order: 1),
    ],
  ),
];

Widget _host({
  required bool furiganaEnabled,
  Map<String, String> readings = const {},
  double textScale = 1.0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          // The platform's text scale is what `MediaQuery.textScalerOf` sees
          // in production (0.85 on the Leaf5C).  Overriding it here is the
          // only way to exercise the slot's scaling in a widget test.
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: SizedBox(
            width: 400,
            height: 600,
            child: TextDisplay(
              paragraphs: _paragraphs(),
              furiganaEnabled: furiganaEnabled,
              furiganaReadings: readings,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The height of the cell holding [word] -- its nearest `Column` ancestor,
/// which is the reading-slot-plus-word column when furigana is on.
double _cellHeight(WidgetTester tester, String word) {
  final column = find
      .ancestor(of: find.text(word), matching: find.byType(Column))
      .first;
  return tester.getSize(column).height;
}

void main() {
  const textSize = 18.0;
  const lineSpacing = 1.5;
  // The forced strut pins every word's line box to fontSize * height.
  const wordLine = textSize * lineSpacing;
  // The reserved reading slot, sized off textSize by the renderer.
  const slot = textSize * 0.7;

  testWidgets('off: no slot, no reading -- the layout is unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(_host(furiganaEnabled: false));

    expect(find.text('夜'), findsOneWidget);
    expect(find.text('の'), findsOneWidget);
    expect(find.text('よる'), findsNothing);
    expect(
      tester.getSize(find.text('夜')).height,
      closeTo(wordLine, 1.0),
      reason: 'with furigana off the cell is just the word line box',
    );
  });

  testWidgets('on: the reading shows above the word, every cell equally tall',
      (tester) async {
    await tester.pumpWidget(
      _host(furiganaEnabled: true, readings: {'0-0-1': 'よる'}),
    );

    expect(find.text('よる'), findsOneWidget, reason: '夜 must show its reading');
    expect(find.text('夜'), findsOneWidget);
    expect(find.text('の'), findsOneWidget);

    expect(
      _cellHeight(tester, '夜'),
      closeTo(slot + wordLine, 1.0),
      reason: 'annotated cell = reading slot + word line box',
    );
    expect(
      _cellHeight(tester, 'の'),
      closeTo(slot + wordLine, 1.0),
      reason: 'a word with no reading must reserve the same slot, '
          'or the line comes out ragged',
    );
  });

  testWidgets('on but readings not in yet: the slot is reserved anyway', (
    tester,
  ) async {
    await tester.pumpWidget(_host(furiganaEnabled: true));

    expect(find.text('よる'), findsNothing);
    expect(
      _cellHeight(tester, '夜'),
      closeTo(slot + wordLine, 1.0),
      reason: 'reserving the space up front is what stops the text jumping '
          'when the readings land',
    );
  });

  testWidgets('the slot follows the platform text scale', (tester) async {
    // A `SizedBox` is measured in logical pixels, so unlike the text inside it
    // it is untouched by the platform's text scale.  A slot that ignored the
    // scale would be outgrown by the reading as the system font size grows --
    // past a scale of ~1.4 the reading is taller than its slot and spills onto
    // the word below.  So the whole cell has to scale as one unit.
    Future<double> cellAt(double scale) async {
      await tester.pumpWidget(
        _host(furiganaEnabled: true, readings: {'0-0-1': 'よる'}, textScale: scale),
      );
      return _cellHeight(tester, '夜');
    }

    final plain = await cellAt(1.0);
    final large = await cellAt(2.0);

    expect(
      large,
      closeTo(plain * 2, 1.0),
      reason: 'doubling the platform text scale must double the whole cell -- '
          'slot and word line together -- or the reading stops fitting',
    );
  });
}
