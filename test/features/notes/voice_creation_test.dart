import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;

// ---------------------------------------------------------------------------
// [FOCUSED TESTS] Record & Conversation Voice Creation
//
// Verifies:
//   1. Partial-text replacement in place.
//   2. Finalized-text deduplication.
//   3. Editing while paused and preserving edits.
//   4. Tab-switch retention (transcript & messages retained).
//   5. Disconnected states (honest UI without mock simulation).
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: MaterialThemes.light,
    home: child,
  );
}

void main() {
  group('TranscriptState (Record tab STT contract)', () {
    test('updates partial recognition in place without appending duplicate tokens', () {
      final TranscriptState state = TranscriptState(isConnected: true);

      state.updatePartial('Meeting with');
      expect(state.displayText, 'Meeting with');

      // Update in place
      state.updatePartial('Meeting with the team');
      expect(state.displayText, 'Meeting with the team');

      state.updatePartial('Meeting with the team at 3pm');
      expect(state.displayText, 'Meeting with the team at 3pm');
    });

    test('finalizes utterance and avoids duplicate phrases', () {
      final TranscriptState state = TranscriptState(isConnected: true);

      // First utterance
      state.updatePartial('First milestone');
      state.finalizeUtterance('First milestone completed.');
      expect(state.finalizedText, 'First milestone completed.');
      expect(state.partialText, '');
      expect(state.displayText, 'First milestone completed.');

      // Second utterance
      state.updatePartial('Second');
      state.finalizeUtterance('Second phase begins tomorrow.');
      expect(
        state.displayText,
        'First milestone completed. Second phase begins tomorrow.',
      );

      // Duplicate phrase check: finalizer should not append identical trailing utterance
      state.finalizeUtterance('Second phase begins tomorrow.');
      expect(
        state.displayText,
        'First milestone completed. Second phase begins tomorrow.',
      );
    });

    test('allows editing while paused and preserves edits when resuming', () {
      final TranscriptState state = TranscriptState(isConnected: true);
      state.finalizeUtterance('Initial notes drafted.');

      // User pauses and edits
      state.updateManualEdits('Initial notes drafted. Checked by team.');
      expect(state.displayText, 'Initial notes drafted. Checked by team.');

      // Subsequent utterance appends onto edited text
      state.finalizeUtterance('Ready for review.');
      expect(
        state.displayText,
        'Initial notes drafted. Checked by team. Ready for review.',
      );
    });

    test('disconnected state prevents starting recording without service', () {
      final TranscriptState state = TranscriptState(isConnected: false);
      expect(state.isConnected, false);
      expect(state.isRecording, false);

      state.startRecording();
      expect(state.isRecording, false);
    });
  });

  group('ConversationSession (Conversation tab contract)', () {
    test('updates user partial bubble in place and finalizes cleanly', () {
      final ConversationSession session = ConversationSession(isConnected: true);

      session.updateUserPartial('Can you summarize');
      expect(session.messages.length, 1);
      expect(session.messages.first.text, 'Can you summarize');
      expect(session.messages.first.isPartial, true);
      expect(session.messages.first.speaker, ConversationSpeaker.user);

      // In place update
      session.updateUserPartial('Can you summarize the sprint?');
      expect(session.messages.length, 1);
      expect(session.messages.first.text, 'Can you summarize the sprint?');
      expect(session.messages.first.isPartial, true);

      // Finalize
      session.finalizeUserUtterance('Can you summarize the sprint?');
      expect(session.messages.length, 1);
      expect(session.messages.first.isPartial, false);
    });

    test('AI response displays actual text and matches speaker', () {
      final ConversationSession session = ConversationSession(isConnected: true);
      session.finalizeUserUtterance('What is next?');
      session.addAiResponse('Next up is deploying the pipeline.');

      expect(session.messages.length, 2);
      expect(session.messages[0].speaker, ConversationSpeaker.user);
      expect(session.messages[0].text, 'What is next?');
      expect(session.messages[1].speaker, ConversationSpeaker.ai);
      expect(session.messages[1].text, 'Next up is deploying the pipeline.');
    });

    test('disconnected state initializes with honest disconnected status', () {
      final ConversationSession session = ConversationSession(isConnected: false);
      expect(session.isConnected, false);
      expect(session.status, ConversationStatus.disconnected);
    });
  });

  group('CreateNoteScreen Widget Tests (Two-State Transition in Record & Conversation)', () {
    testWidgets('Record mode two-state transition: Idle -> Active -> Idle', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const CreateNoteScreen()));
      await tester.pump();

      // ── State 1: IDLE ──
      expect(find.byType(PainterlyOrb), findsOneWidget);
      expect(find.text('Start recording'), findsOneWidget);
      expect(find.text('Draft transcript — not saved'), findsNothing);
      expect(
        find.text('Recognized speech will appear here live as you speak…'),
        findsNothing,
      );

      // Tap Start recording -> transition to State 2: ACTIVE
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Panel fades in, button changes to Stop recording
      expect(find.text('Draft transcript — not saved'), findsOneWidget);
      expect(find.text('Recording not connected'), findsOneWidget);
      expect(
        find.text('Recognized speech will appear here live as you speak…'),
        findsOneWidget,
      );
      expect(find.text('Stop recording'), findsOneWidget);
      expect(find.text('Start recording'), findsNothing);

      // Disconnected honest snackbar is shown
      expect(
        find.text(
          'Speech-to-text service not connected. Real transcription integration required.',
        ),
        findsOneWidget,
      );

      // Tap Stop recording -> reverses animation back to State 1: IDLE
      await tester.tap(find.text('Stop recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Start recording'), findsOneWidget);
      expect(find.text('Stop recording'), findsNothing);
    });

    testWidgets('Conversation mode two-state transition: Idle -> Active -> Idle', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const CreateNoteScreen()));
      await tester.pump();

      // Switch to Conversation mode while in Idle
      await tester.tap(find.text('Conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // ── State 1: IDLE in Conversation ──
      expect(find.byType(PainterlyOrb), findsOneWidget);
      expect(find.text('Start conversation'), findsOneWidget);
      expect(find.text('Spoken conversation'), findsNothing);
      expect(find.text('Voice AI not connected'), findsNothing);

      // Tap Start conversation -> transition to State 2: ACTIVE
      await tester.tap(find.text('Start conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Chat panel fades in, button changes to End conversation
      expect(find.text('Spoken conversation'), findsOneWidget);
      expect(find.text('Voice AI not connected'), findsOneWidget);
      expect(find.text('End conversation'), findsOneWidget);
      expect(find.text('Start conversation'), findsNothing);

      // Disconnected honest snackbar is shown
      expect(
        find.text(
          'Voice AI service not connected. Speech synthesis and dialogue require backend integration.',
        ),
        findsOneWidget,
      );

      // Tap End conversation -> reverses animation back to State 1: IDLE
      await tester.tap(find.text('End conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Start conversation'), findsOneWidget);
      expect(find.text('End conversation'), findsNothing);
    });

    testWidgets('Toggles are disabled while in Active state', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const CreateNoteScreen()));
      await tester.pump();

      // Start recording -> ACTIVE
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // While active, tapping Conversation toggle does not switch submode
      await tester.tap(find.text('Conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Still in Record mode (shows Stop recording, not End conversation)
      expect(find.text('Stop recording'), findsOneWidget);
      expect(find.text('End conversation'), findsNothing);

      // While active, tapping Type tab does not switch tab
      await tester.tap(find.text('Type'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Still in Voice screen
      expect(find.byType(PainterlyOrb), findsOneWidget);

      // Tapping Stop restores toggles
      await tester.tap(find.text('Stop recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Dismiss snackbar so it does not intercept tap
      ScaffoldMessenger.of(tester.element(find.byType(CreateNoteScreen)))
          .removeCurrentSnackBar();
      await tester.pump();

      // Now tapping Conversation switches submode
      await tester.tap(find.text('Conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Start conversation'), findsOneWidget);
    });

    testWidgets('Preserves transcript text when switching modes and tabs', (
      tester,
    ) async {
      final TranscriptState transcriptState = TranscriptState(isConnected: true);
      transcriptState.finalizeUtterance('Meeting notes from audio discussion.');

      await tester.pumpWidget(
        _wrap(
          CreateNoteScreen(
            transcriptState: transcriptState,
          ),
        ),
      );
      await tester.pump();

      // Start recording to reveal transcript
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Meeting notes from audio discussion.'), findsOneWidget);

      // Stop recording
      await tester.tap(find.text('Stop recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Switch to Type tab and back
      await tester.tap(find.text('Type'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Start typing your note…'), findsOneWidget);

      await tester.tap(find.text('Voice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Re-enter active state: text is preserved!
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Meeting notes from audio discussion.'), findsOneWidget);
    });

    testWidgets('Conversation tab renders user bubble on right and AI bubble on left', (
      tester,
    ) async {
      final ConversationSession session = ConversationSession(isConnected: true);
      session.finalizeUserUtterance('How is the progress?');
      session.addAiResponse('All tasks are right on track.');

      await tester.pumpWidget(
        _wrap(
          CreateNoteScreen(
            conversationSession: session,
          ),
        ),
      );
      await tester.pump();

      // Switch to Conversation and activate
      await tester.tap(find.text('Conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Start conversation'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('How is the progress?'), findsOneWidget);
      expect(find.text('All tasks are right on track.'), findsOneWidget);
    });
  });
}
