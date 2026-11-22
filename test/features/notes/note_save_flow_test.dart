import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bunpod/features/notes/cubits/latest_note_cubit.dart';
import 'package:bunpod/features/notes/models/note.dart';
import 'package:bunpod/features/notes/models/voice_note_state.dart';
import 'package:bunpod/features/notes/pages/create_note_placeholder_page.dart';
import 'package:bunpod/features/notes/pages/note_audio_page.dart';
import 'package:bunpod/features/notes/services/notes_repository.dart';
import 'package:bunpod/features/notes/services/voice_note_audio.dart';
import 'package:bunpod/features/notes/stt/stt_adapter.dart';
import 'package:audio_service/audio_service.dart';
import 'package:bunpod/features/player/services/note_audio_player_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final List<File> _testAudioFiles = <File>[];

class _FakeVoiceCapture implements PcmVoiceNoteAudioCapture {
  _FakeVoiceCapture(this.path);

  final String path;
  int stopCalls = 0;

  @override
  set onPcmChunk(void Function(Uint8List pcm16LittleEndian)? callback) {}

  @override
  Future<void> start() async {}

  @override
  Future<VoiceAudioSegment> stop() async {
    stopCalls++;
    final File audio = File(path);
    if (!_testAudioFiles.contains(audio)) _testAudioFiles.add(audio);
    audio.writeAsBytesSync(List<int>.filled(1024, 0x31), flush: true);
    return VoiceAudioSegment(
      path: path,
      duration: const Duration(milliseconds: 7987),
      fileSizeBytes: audio.lengthSync(),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _CapturingPlayerHandler implements NoteAudioPlayerHandler {
  List<String>? loadedPaths;
  int playCalls = 0;
  final StreamController<PlaybackState> _playback =
      StreamController<PlaybackState>.broadcast();

  @override
  Stream<PlaybackState> get playbackState => _playback.stream;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  bool get isPlaying => false;

  @override
  Future<void> loadNoteAudio({
    required String id,
    required String title,
    required String audioUrl,
    List<String> localAudioPaths = const <String>[],
    Duration? duration,
  }) async {
    loadedPaths = localAudioPaths;
  }

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}
}

class _MemoryAudioReferenceStore extends LocalNoteAudioStore {
  static final Map<String, LocalNoteAudioReference> references =
      <String, LocalNoteAudioReference>{};

  @override
  Future<void> save(String noteId, LocalNoteAudioReference reference) async {
    references[noteId] = reference;
  }

  @override
  Future<LocalNoteAudioReference?> read(String noteId) async =>
      references[noteId];

  @override
  Future<List<Note>> attachToNotes(Iterable<Note> notes) async => <Note>[
    for (final Note note in notes)
      if (references[note.id] case final LocalNoteAudioReference reference)
        note.copyWith(
          localAudioPaths: reference.paths,
          localAudioFileSizeBytes: reference.fileSizeBytes,
          duration: reference.duration,
          audioRecordingFailed: reference.recordingFailed,
        )
      else
        note,
  ];
}

class _FailOnceAudioReferenceStore extends _MemoryAudioReferenceStore {
  int saveCalls = 0;

  @override
  Future<void> save(String noteId, LocalNoteAudioReference reference) async {
    saveCalls++;
    if (saveCalls == 1) throw StateError('simulated local reference failure');
    await super.save(noteId, reference);
  }
}

class FakeRecordStt extends SttAdapter implements PcmInputSttAdapter {
  SttStatus _status = SttStatus.idle;
  String _partial = '';
  String _final = '';
  String? finalOnStop;

  @override
  SttStatus get status => _status;
  @override
  String get lastError => '';
  @override
  String get partialText => _partial;
  @override
  String get finalText => _final;
  @override
  Future<SttInitResult> initialize() async => SttInitResult.ready;

  @override
  Future<void> start() async {
    _partial = '';
    _final = '';
    _status = SttStatus.listening;
    notifyListeners();
  }

  void speak(String text) {
    _partial = text;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    if (finalOnStop case final String text) {
      _final = text;
      _partial = '';
      notifyListeners();
    }
    _status = SttStatus.stopped;
    notifyListeners();
  }

  @override
  void addPcmChunk(Uint8List pcm16LittleEndian, {required int sampleRate}) {}

  @override
  void pause() {
    _status = SttStatus.paused;
    notifyListeners();
  }

  @override
  Future<void> resume() => start();
}

class TestNotesRepository extends InMemoryNotesRepository {
  bool failSave = false;
  int saveCalls = 0;

  @override
  Future<void> saveNote(Note note) async {
    saveCalls++;
    if (failSave) throw StateError('database unavailable');
    await super.saveNote(note);
  }

  Future<void> saveToMemory(Note note) => super.saveNote(note);
}

class BlockingNotesRepository extends TestNotesRepository {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> saveNote(Note note) async {
    saveCalls++;
    started.complete();
    await release.future;
    await saveToMemory(note);
  }
}

Future<void> _openRecord(
  WidgetTester tester, {
  required FakeRecordStt adapter,
  required TestNotesRepository repository,
  required LatestNoteCubit cubit,
  required TranscriptState transcript,
  VoiceNoteAudioCapture Function()? voiceAudioCaptureFactory,
  LocalNoteAudioStore? localNoteAudioStore,
}) async {
  final VoiceNoteAudioCapture Function() captureFactory =
      voiceAudioCaptureFactory ??
      () => _FakeVoiceCapture(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'record-test-${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => CreateNoteScreen(
                  transcriptState: transcript,
                  sttAdapter: adapter,
                  latestNoteCubit: cubit,
                  notesRepository: repository,
                  userId: 'user-1',
                  voiceAudioCaptureFactory: captureFactory,
                  localNoteAudioStore:
                      localNoteAudioStore ?? _MemoryAudioReferenceStore(),
                ),
              ),
            ),
            child: const Text('Open Record'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open Record'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.text('Start recording'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> _stopAndOpenCategory(WidgetTester tester) async {
  await tester.tap(find.text('Stop & finish'));
  for (
    int i = 0;
    i < 50 && find.text('Choose a category').evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _enterCategory(WidgetTester tester, String category) async {
  await tester.enterText(find.byKey(const Key('new-category')), category);
  await tester.pump();
  final Finder saveButton = find.widgetWithText(FilledButton, 'Save');
  await tester.ensureVisible(saveButton);
  tester.widget<FilledButton>(saveButton).onPressed!.call();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    for (final File file in _testAudioFiles) {
      if (file.existsSync()) file.deleteSync();
    }
    _testAudioFiles.clear();
  });

  testWidgets(
    'Stop saves the transcript draft with the finalized recording',
    (
      tester,
    ) async {
      final repository = TestNotesRepository();
      final cubit = LatestNoteCubit(repository: repository);
      final adapter = FakeRecordStt();
      final transcript = TranscriptState(isConnected: true);
      transcript.updateManualEdits('First line\nFinal words');
      await _openRecord(
        tester,
        adapter: adapter,
        repository: repository,
        cubit: cubit,
        transcript: transcript,
      );
      await _start(tester);
      await _stopAndOpenCategory(tester);
      expect(find.text('Choose a category'), findsOneWidget);
      await _enterCategory(tester, 'Work');
      await tester.pump(const Duration(milliseconds: 500));

      final Note? saved = cubit.state.latestNote;
      expect(saved, isNotNull);
      expect(saved!.userId, 'user-1');
      expect(saved.category, 'Work');
      expect(cubit.state.selectedCategory, 'Work');
      expect(cubit.state.filteredNotes.single.id, saved.id);
      expect(saved.title, 'First line');
      expect(saved.transcript, 'First line\nFinal words');
      expect(saved.hasAudio, isTrue);
      expect(saved.localAudioPaths, hasLength(1));
      expect(cubit.state.notes.first.id, saved.id);
      expect(cubit.state.categories, contains('Work'));
      expect(transcript.displayText, isEmpty);
      expect(repository.saveCalls, 1);
    },
  );

  testWidgets(
    'empty-transcript Record saves finalized audio for a fresh-store player',
    (tester) async {
      final String path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'record-empty-${DateTime.now().microsecondsSinceEpoch}.m4a';
      final File audio = File(path);
      addTearDown(() {
        if (audio.existsSync()) audio.deleteSync();
      });
      final TestNotesRepository repository = TestNotesRepository();
      final LatestNoteCubit cubit = LatestNoteCubit(repository: repository);
      final _FakeVoiceCapture capture = _FakeVoiceCapture(path);
      final _MemoryAudioReferenceStore store = _MemoryAudioReferenceStore();
      _MemoryAudioReferenceStore.references.clear();
      await _openRecord(
        tester,
        adapter: FakeRecordStt(),
        repository: repository,
        cubit: cubit,
        transcript: TranscriptState(isConnected: true),
        voiceAudioCaptureFactory: () => capture,
        localNoteAudioStore: store,
      );

      await _start(tester);
      await _stopAndOpenCategory(tester);
      expect(capture.stopCalls, 1);
      expect(find.text('Choose a category'), findsOneWidget);
      await _enterCategory(tester, 'Work');
      for (int i = 0; i < 50 && cubit.state.latestNote == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final Note saved = cubit.state.latestNote!;
      expect(saved.transcript, isNull);
      expect(saved.localAudioPaths, <String>[path]);
      expect(saved.hasAudio, isTrue);
      final Note reopened = (await _MemoryAudioReferenceStore().attachToNotes(
        <Note>[
          Note(
            id: saved.id,
            userId: saved.userId,
            title: saved.title,
            preview: saved.preview,
            transcript: saved.transcript,
            createdAt: saved.createdAt,
          ),
        ],
      )).single;
      final _CapturingPlayerHandler handler = _CapturingPlayerHandler();
      final PlayerHandlerNoteAudioPlaybackController controller =
          PlayerHandlerNoteAudioPlaybackController(
            note: reopened,
            handler: handler,
          );
      await controller.play();

      expect(reopened.localAudioPaths, <String>[path]);
      expect(handler.loadedPaths, <String>[path]);
      expect(handler.playCalls, 1);
      await tester.runAsync(controller.dispose);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Cancel keeps the stopped transcript draft', (tester) async {
    final repository = TestNotesRepository();
    final cubit = LatestNoteCubit(repository: repository);
    final adapter = FakeRecordStt()..finalOnStop = 'Keep this transcript';
    final transcript = TranscriptState(isConnected: true);
    await _openRecord(
      tester,
      adapter: adapter,
      repository: repository,
      cubit: cubit,
      transcript: transcript,
    );
    await _start(tester);
    await _stopAndOpenCategory(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(transcript.displayText, 'Keep this transcript');
    expect(cubit.state.notes, isEmpty);
    expect(repository.saveCalls, 0);
    expect(find.text('Finish note'), findsOneWidget);
  });

  testWidgets('audio-reference failure can be retried without rerecording', (
    tester,
  ) async {
    final String path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'record-retry-${DateTime.now().microsecondsSinceEpoch}.m4a';
    final File audio = File(path);
    addTearDown(() {
      if (audio.existsSync()) audio.deleteSync();
    });
    final TestNotesRepository repository = TestNotesRepository();
    final LatestNoteCubit cubit = LatestNoteCubit(repository: repository);
    final _FakeVoiceCapture capture = _FakeVoiceCapture(path);
    final _FailOnceAudioReferenceStore store = _FailOnceAudioReferenceStore();
    _MemoryAudioReferenceStore.references.clear();
    await _openRecord(
      tester,
      adapter: FakeRecordStt(),
      repository: repository,
      cubit: cubit,
      transcript: TranscriptState(isConnected: true),
      voiceAudioCaptureFactory: () => capture,
      localNoteAudioStore: store,
    );

    await _start(tester);
    await _stopAndOpenCategory(tester);
    await _enterCategory(tester, 'Work');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.textContaining('recording could not be attached'),
      findsOneWidget,
    );
    final String savedNoteId = cubit.state.latestNote!.id;
    expect(capture.stopCalls, 1);

    await tester.tap(find.text('Finish note'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await _enterCategory(tester, 'Work');
    await tester.pump(const Duration(milliseconds: 500));

    expect(store.saveCalls, 2);
    expect(cubit.state.latestNote?.id, savedNoteId);
    expect(capture.stopCalls, 1);
    expect(_MemoryAudioReferenceStore.references[savedNoteId]?.paths, <String>[
      path,
    ]);
  });

  testWidgets('Type saves the text controller value as a note', (tester) async {
    final TestNotesRepository repository = TestNotesRepository();
    final LatestNoteCubit cubit = LatestNoteCubit(repository: repository);
    await _openRecord(
      tester,
      adapter: FakeRecordStt(),
      repository: repository,
      cubit: cubit,
      transcript: TranscriptState(isConnected: true),
    );

    await tester.tap(find.text('Type'));
    await tester.pump(const Duration(milliseconds: 300));
    const String typedText = 'Typed note content';
    await tester.enterText(find.byType(TextField), typedText);
    await tester.pump();
    await tester.tap(find.text('Finish note'));
    await tester.pump();
    for (
      int i = 0;
      i < 50 && find.text('Choose a category').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _enterCategory(tester, 'Ideas');

    expect(repository.saveCalls, 1);
    expect(cubit.state.latestNote?.title, typedText);
    expect(cubit.state.latestNote?.preview, typedText);
    expect(cubit.state.latestNote?.transcript, typedText);
  });

  testWidgets('Type shows an error instead of saving empty text', (
    tester,
  ) async {
    final TestNotesRepository repository = TestNotesRepository();
    final LatestNoteCubit cubit = LatestNoteCubit(repository: repository);
    await _openRecord(
      tester,
      adapter: FakeRecordStt(),
      repository: repository,
      cubit: cubit,
      transcript: TranscriptState(isConnected: true),
    );

    await tester.tap(find.text('Type'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Finish note'));
    await tester.pump();

    expect(find.text('Enter some text before saving.'), findsOneWidget);
    expect(repository.saveCalls, 0);
    expect(find.text('Choose a category'), findsNothing);
  });

  testWidgets('Save failure keeps the draft and allows retry', (tester) async {
    final repository = TestNotesRepository()..failSave = true;
    final cubit = LatestNoteCubit(repository: repository);
    final adapter = FakeRecordStt()..finalOnStop = 'Retry this transcript';
    final transcript = TranscriptState(isConnected: true);
    await _openRecord(
      tester,
      adapter: adapter,
      repository: repository,
      cubit: cubit,
      transcript: transcript,
    );
    await _start(tester);
    await _stopAndOpenCategory(tester);
    await _enterCategory(tester, 'Ideas');
    await tester.pump(const Duration(milliseconds: 500));

    expect(transcript.displayText, 'Retry this transcript');
    expect(find.textContaining('Could not save the note'), findsOneWidget);
    expect(cubit.state.notes, isEmpty);

    repository.failSave = false;
    await tester.tap(find.text('Finish note'));
    await tester.pump();
    await _enterCategory(tester, 'Ideas');
    await tester.pump(const Duration(milliseconds: 500));
    expect(cubit.state.latestNote?.transcript, 'Retry this transcript');
    expect(repository.saveCalls, 2);
  });

  testWidgets('Repeated Finish taps cannot start duplicate saves', (
    tester,
  ) async {
    final repository = BlockingNotesRepository();
    final cubit = LatestNoteCubit(repository: repository);
    final adapter = FakeRecordStt()..finalOnStop = 'Save once';
    final transcript = TranscriptState(isConnected: true);
    transcript.updateManualEdits('Save once');
    await _openRecord(
      tester,
      adapter: adapter,
      repository: repository,
      cubit: cubit,
      transcript: transcript,
    );
    await _start(tester);
    await _stopAndOpenCategory(tester);
    await _enterCategory(tester, 'Tasks');
    await tester.pump();
    await repository.started.future;

    await tester.tap(find.text('Finish note'));
    await tester.pump();
    expect(repository.saveCalls, 1);

    repository.release.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(cubit.state.notes, hasLength(1));
  });
}
