import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:material_wavy_progress_indicator/material_wavy_progress_indicator.dart';

import '../../../lib/features/player/widgets/player_screen_layout.dart';

void main() {
  testWidgets('no-audio screen shows full layout with disabled controls', (
    tester,
  ) async {
    tester.view.physicalSize = const material_ui.Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Note note = Note(
      id: 'no-audio',
      userId: 'user-1',
      title: 'A transcript only note',
      preview: 'Transcript text.',
      transcript: 'Transcript text.',
      createdAt: DateTime(2026, 8, 20, 11, 3),
    );

    await tester.pumpWidget(
      material_ui.MaterialApp(
        theme: MaterialThemes.light,
        home: NoteAudioPage(note: note),
      ),
    );
    await tester.pump();

    expect(
      find.text('No audio recorded for this note yet.'),
      findsOneWidget,
    );
    expect(find.text('A transcript only note'), findsNothing);
    expect(find.text('Transcript text.'), findsOneWidget);
    expect(find.byType(material_ui.SelectableText), findsOneWidget);
    expect(find.text('No transcript available'), findsNothing);
    expect(find.textContaining('Thu, Aug 20 11:03 AM'), findsNothing);
    expect(find.byType(PlayerScreenLayout), findsOneWidget);
    expect(find.byType(WavyLinearProgressIndicator), findsOneWidget);
    final PlayerControls controls = tester.widget(find.byType(PlayerControls));
    expect(controls.enabled, isFalse);
    final material_ui.IgnorePointer controlsDisable = tester.widget(
      find
          .ancestor(
            of: find.byType(PlayerControls),
            matching: find.byType(material_ui.IgnorePointer),
          )
          .first,
    );
    expect(controlsDisable.ignoring, isTrue);
    expect(find.byType(SeekButton), findsNWidgets(2));
    expect(find.byIcon(material_ui.Icons.graphic_eq_rounded), findsNothing);
    expect(find.text('0s'), findsOneWidget);
  });

  testWidgets('conversation transcript shows saved turns in order', (
    tester,
  ) async {
    tester.view.physicalSize = const material_ui.Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Note note = Note(
      id: 'conversation',
      userId: 'user-1',
      title: 'Generated card title',
      preview: 'Preview only',
      transcript: 'Combined text is not used for conversations.',
      conversationMessages: const [
        {
          'speaker': 'user',
          'text': '  First saved turn!  ',
          'timestamp': 't1',
        },
        {'speaker': 'ai', 'text': 'Second saved turn?', 'timestamp': 't2'},
      ],
      createdAt: DateTime(2026, 8, 20, 11, 3),
    );

    await tester.pumpWidget(
      material_ui.MaterialApp(
        theme: MaterialThemes.light,
        home: NoteAudioPage(note: note),
      ),
    );
    await tester.pump();

    expect(find.text('Generated card title'), findsNothing);
    expect(find.text('Preview only'), findsNothing);
    expect(
      find.text('Combined text is not used for conversations.'),
      findsNothing,
    );
    expect(find.text('You'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    final material_ui.SelectableText first = tester.widget(
      find.byWidgetPredicate(
        (widget) =>
            widget is material_ui.SelectableText &&
            widget.data == '  First saved turn!  ',
      ),
    );
    final material_ui.SelectableText second = tester.widget(
      find.byWidgetPredicate(
        (widget) =>
            widget is material_ui.SelectableText &&
            widget.data == 'Second saved turn?',
      ),
    );
    expect(
      tester.getTopLeft(find.byWidget(first)).dy,
      lessThan(tester.getTopLeft(find.byWidget(second)).dy),
    );
  });

  testWidgets('missing saved transcript shows the explicit empty state', (
    tester,
  ) async {
    final Note note = Note(
      id: 'empty-transcript',
      userId: 'user-1',
      title: 'A title is not a transcript',
      preview: 'A preview is not a transcript',
      createdAt: DateTime(2026, 8, 20),
    );

    await tester.pumpWidget(
      material_ui.MaterialApp(
        theme: MaterialThemes.light,
        home: NoteAudioPage(note: note),
      ),
    );

    expect(find.text('No transcript available'), findsOneWidget);
    expect(find.text('A title is not a transcript'), findsNothing);
    expect(find.text('A preview is not a transcript'), findsNothing);
  });

  testWidgets(
    'long transcript scrolls within the space above playback controls',
    (tester) async {
      tester.view.physicalSize = const material_ui.Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final Note note = Note(
        id: 'long-transcript',
        userId: 'user-1',
        title: 'Ignored title',
        preview: 'Ignored preview',
        transcript: List<String>.filled(120, 'Saved speech words.').join(' '),
        createdAt: DateTime(2026, 8, 20),
      );

      await tester.pumpWidget(
        material_ui.MaterialApp(
          theme: MaterialThemes.light,
          home: NoteAudioPage(note: note),
        ),
      );

      expect(find.byType(material_ui.ListView), findsOneWidget);
      expect(find.byType(PlayerControls), findsOneWidget);
      expect(
        tester.getRect(find.byType(PlayerControls)).bottom,
        lessThan(800),
      );
    },
  );
}
