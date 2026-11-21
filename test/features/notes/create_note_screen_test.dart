import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expressive_shapes/expressive_shapes.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;

// ---------------------------------------------------------------------------
// [WIDGET] CreateNoteScreen & Floating + Button
//
// Verifies:
//   1. Floating + button renders and taps to open the creation screen.
//   2. Default selection is Voice tab (shows PainterlyOrb and Record submode).
//   3. Switching to Type tab and entering text preserves draft across tab changes.
//   4. Record mode renders disabled control with "Recording not connected".
//   5. Conversation mode renders disabled control with "Voice AI not connected".
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: MaterialThemes.light,
    home: child,
  );
}

void main() {
  testWidgets('Floating + button renders and taps to open CreateNoteScreen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Builder(
            builder: (context) => Tooltip(
              message: 'New note',
              child: Material(
                color: Colors.amber,
                shape: MaterialShapeBorder(
                  shape: MaterialShapes.cookie7Sided,
                ),
                child: InkWell(
                  onTap: () => CreateNoteScreen.open(context),
                  child: const SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(Icons.add_rounded),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Verify button rendered
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.byTooltip('New note'), findsOneWidget);

    // Tap + button to open creation screen
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Verify CreateNoteScreen opened
    expect(find.byType(CreateNoteScreen), findsOneWidget);
    expect(find.text('New note'), findsOneWidget);
  });

  testWidgets('Default selection is Voice tab with painterly orb', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CreateNoteScreen()));
    await tester.pump();

    // Voice tab should be default
    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.byType(PainterlyOrb), findsOneWidget);

    // Sub-mode controls should be visible
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
  });

  testWidgets('Record and Conversation modes render their disabled placeholder states', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CreateNoteScreen()));
    await tester.pump();

    // Record mode is selected by default in State 1 (Idle)
    expect(find.text('Start recording'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

    // Tap Start recording -> State 2 (Active) reveals transcript panel with honest status
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Recording not connected'), findsOneWidget);
    expect(find.text('Stop recording'), findsOneWidget);

    // Tap Stop recording -> returns to State 1 (Idle)
    await tester.tap(find.text('Stop recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Dismiss snackbar so it does not intercept tap
    ScaffoldMessenger.of(tester.element(find.byType(CreateNoteScreen)))
        .removeCurrentSnackBar();
    await tester.pump();

    // Switch to Conversation mode
    await tester.tap(find.text('Conversation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Conversation mode in State 1 (Idle)
    expect(find.text('Start conversation'), findsOneWidget);
    expect(find.byIcon(Icons.record_voice_over_rounded), findsOneWidget);

    // Tap Start conversation -> State 2 (Active) reveals chat panel with honest status
    await tester.tap(find.text('Start conversation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('End conversation'), findsOneWidget);
    expect(find.text('Voice AI not connected'), findsOneWidget);
  });

  testWidgets('Switching to Type and entering text preserves draft after switching back and forth', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CreateNoteScreen()));
    await tester.pump();

    // Switch to Type tab
    await tester.tap(find.text('Type'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // TextField is present
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Draft — not saved'), findsOneWidget);

    // Enter draft text
    const String testDraft = 'Antigravity pair programming notes: state preserved!';
    await tester.enterText(find.byType(TextField), testDraft);
    await tester.pump();

    expect(find.text(testDraft), findsOneWidget);

    // Switch back to Voice tab
    await tester.tap(find.text('Voice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // PainterlyOrb is back
    expect(find.byType(PainterlyOrb), findsOneWidget);
    expect(find.text(testDraft), findsNothing);

    // Switch back to Type tab
    await tester.tap(find.text('Type'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Verify draft text is preserved
    expect(find.text(testDraft), findsOneWidget);
  });
}
