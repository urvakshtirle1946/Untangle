import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material_ui;

material_ui.Widget _wrap(material_ui.Widget child) => material_ui.MaterialApp(
  theme: MaterialThemes.light,
  home: child,
);

void main() {
  final DateTime createdAt = DateTime(2026, 8, 20, 11, 3);
  final Note record = Note(
    id: 'record-1',
    userId: 'user-1',
    title: 'Garden planning',
    preview: 'Plant herbs this weekend. Water the seedlings.',
    transcript: 'Plant herbs this weekend. Water the seedlings.',
    createdAt: createdAt,
    summaryStatus: 'ready',
    summaryTitle: 'Plan the herb garden',
    summarySections: const [
      {
        'heading': 'Next steps',
        'bullets': ['Plant herbs this weekend.', 'Water the seedlings.'],
      },
    ],
  );
  final Note conversation = Note(
    id: 'conversation-1',
    userId: 'user-1',
    title: 'Planning a trip',
    preview: 'Let’s visit Jaipur.',
    transcript: 'User: Let’s visit Jaipur.\nAI: What would you like to see?',
    conversationMessages: const [
      {'speaker': 'user', 'text': 'Let’s visit Jaipur.'},
      {'speaker': 'ai', 'text': 'What would you like to see?'},
    ],
    createdAt: createdAt,
    summaryStatus: 'failed',
  );

  testWidgets(
    'record detail shows persisted summary and transcript-only player',
    (tester) async {
      await tester.pumpWidget(_wrap(NoteDetailPage(note: record)));
      await tester.pump();
      expect(find.byTooltip('Favorite'), findsOneWidget);
      expect(find.byTooltip('Share note'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
      expect(find.byTooltip('Play recording'), findsOneWidget);
      final material_ui.FloatingActionButton audioButton = tester.widget(
        find.byType(material_ui.FloatingActionButton),
      );
      expect(audioButton.backgroundColor!.a, lessThan(1.0));
      expect(audioButton.onPressed, isNotNull);
      expect(find.text('Audio not available'), findsNothing);
      expect(
        find.byIcon(material_ui.Icons.chat_bubble_outline_rounded),
        findsNothing,
      );
      expect(find.byType(material_ui.LinearProgressIndicator), findsNothing);

      expect(find.text('Plan the herb garden'), findsOneWidget);
      expect(find.text('Next steps'), findsOneWidget);
      expect(find.text('Plant herbs this weekend.'), findsOneWidget);
      await tester.tap(find.byType(material_ui.FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('No audio recorded for this note yet.'), findsOneWidget);
      expect(find.byType(NoteAudioPage), findsOneWidget);
      expect(
        find.text('No audio recorded for this note yet.'),
        findsOneWidget,
      );
      expect(find.text('No audio for this note'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Transcript'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byTooltip('Play recording'), findsOneWidget);
      expect(find.text('Audio not available'), findsNothing);
      expect(find.byType(material_ui.LinearProgressIndicator), findsNothing);
      expect(find.text('You'), findsNWidgets(3));
      expect(find.text('Water the seedlings.'), findsOneWidget);
    },
  );

  testWidgets('conversation transcript preserves the saved speaker order', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(NoteDetailPage(note: conversation)));
    await tester.pump();
    expect(find.byTooltip('Favorite'), findsNothing);
    expect(find.byTooltip('Remove favorite'), findsNothing);
    expect(find.byTooltip('Share note'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.byTooltip('Play recording'), findsOneWidget);
    await tester.tap(find.text('Transcript'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Let’s visit Jaipur.'), findsOneWidget);
    expect(find.text('What would you like to see?'), findsOneWidget);
    expect(find.text('AI'), findsWidgets);
    expect(find.byIcon(material_ui.Icons.auto_awesome_rounded), findsNWidgets(2));
    expect(find.text('Audio not available'), findsNothing);
    expect(find.text('Summary unavailable'), findsNothing);
  });
}
