import 'dart:io';

import 'package:bunpod/features/notes/models/note.dart';
import 'package:bunpod/features/notes/pages/note_audio_page.dart';
import 'package:bunpod/features/notes/services/voice_note_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late Directory audioTestDirectory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  setUpAll(() async {
    audioTestDirectory = await Directory.systemTemp.createTemp(
      'untangle-audio-test-',
    );
  });
  tearDownAll(() async {
    if (await audioTestDirectory.exists()) {
      await audioTestDirectory.delete(recursive: true);
    }
  });

  for (final String mode in <String>['Record', 'Conversation']) {
    test('$mode save and reopen restores the real local file reference', () async {
      final File audio = File(
        '${audioTestDirectory.path}${Platform.pathSeparator}${mode.toLowerCase()}.m4a',
      );
      await audio.writeAsBytes(List<int>.filled(128, 0x41), flush: true);
      final Note saved = Note(
        id: mode.toLowerCase(),
        userId: 'user-1',
        title: '$mode voice note',
        preview: 'recognized speech',
        transcript: 'recognized speech',
        conversationMessages: mode == 'Conversation'
            ? const <Map<String, dynamic>>[
                <String, dynamic>{
                  'speaker': 'user',
                  'text': 'recognized speech',
                },
                <String, dynamic>{'speaker': 'ai', 'text': 'reply'},
              ]
            : null,
        createdAt: DateTime(2026),
        localAudioPaths: <String>[audio.path],
        localAudioFileSizeBytes: await audio.length(),
        duration: const Duration(seconds: 4),
      );
      await LocalNoteAudioStore().save(
        saved.id,
        LocalNoteAudioReference(
          paths: saved.localAudioPaths,
          duration: saved.duration!,
          fileSizeBytes: saved.localAudioFileSizeBytes!,
        ),
      );

      final Note reopened = (await LocalNoteAudioStore().attachToNotes(<Note>[
        Note(
          id: saved.id,
          userId: saved.userId,
          title: saved.title,
          preview: saved.preview,
          transcript: saved.transcript,
          conversationMessages: saved.conversationMessages,
          createdAt: saved.createdAt,
        ),
      ])).single;
      expect(reopened.localAudioPaths, <String>[audio.path]);
      expect(await File(reopened.localAudioPaths.single).exists(), isTrue);
      expect(reopened.localAudioFileSizeBytes, await audio.length());
      expect(reopened.duration, saved.duration);
      expect(reopened.hasAudio, isTrue);
    });
  }

  test('failed capture preserves transcript and is not playable', () async {
    final Note failed = Note(
      id: 'failed-recording',
      userId: 'user-1',
      title: 'Saved transcript',
      preview: 'recognized speech',
      transcript: 'recognized speech',
      createdAt: DateTime(2026),
      audioRecordingFailed: true,
    );
    await LocalNoteAudioStore().save(
      failed.id,
      const LocalNoteAudioReference(
        paths: <String>[],
        duration: Duration.zero,
        fileSizeBytes: 0,
        recordingFailed: true,
      ),
    );
    expect(failed.transcript, 'recognized speech');
    expect(failed.hasAudio, isFalse);
    expect(
      UnavailableNoteAudioPlaybackController(failed).initialErrorMessage,
      'Audio recording failed.',
    );
    expect(
      (await LocalNoteAudioStore().read(failed.id))?.recordingFailed,
      isTrue,
    );
  });
}
