import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bunpod/features/notes/cubits/latest_note_cubit.dart';
import 'package:bunpod/features/notes/models/note.dart';
import 'package:bunpod/features/notes/models/voice_note_state.dart';
import 'package:bunpod/features/notes/pages/create_note_placeholder_page.dart';
import 'package:bunpod/features/notes/services/conversation_ai_client.dart';
import 'package:bunpod/features/notes/services/notes_repository.dart';
import 'package:bunpod/features/notes/services/voice_note_audio.dart';
import 'package:bunpod/features/notes/stt/stt_adapter.dart';
import 'package:bunpod/features/notes/pages/note_audio_page.dart';
import 'package:bunpod/features/player/services/note_audio_player_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSttAdapter extends SttAdapter {
  SttStatus _status = SttStatus.idle;
  String _partial = '';
  String _final = '';
  String _error = '';
  String _errorCode = '';
  String _statusEvent = '';
  int _sessionGeneration = 0;
  int? _currentListenGeneration;
  int? _resultSessionGeneration;
  int? _resultListenGeneration;
  int startCount = 0;
  bool delayNextStart = false;

  @override
  SttStatus get status => _status;
  @override
  String get lastError => _error;
  @override
  String get lastErrorCode => _errorCode;
  @override
  String get lastStatusEvent => _statusEvent;
  @override
  int? get currentSessionGeneration => _sessionGeneration;
  @override
  int? get currentListenGeneration => _currentListenGeneration;
  @override
  int? get resultSessionGeneration => _resultSessionGeneration;
  @override
  int? get resultListenGeneration => _resultListenGeneration;
  @override
  String get partialText => _partial;
  @override
  String get finalText => _final;
  @override
  Future<SttInitResult> initialize() async => SttInitResult.ready;

  @override
  int beginSession() {
    _sessionGeneration++;
    _currentListenGeneration = null;
    _resultSessionGeneration = null;
    _resultListenGeneration = null;
    _partial = '';
    _final = '';
    _error = '';
    _errorCode = '';
    _statusEvent = '';
    return _sessionGeneration;
  }

  @override
  Future<void> start() => startForSession(
    _sessionGeneration,
    (_currentListenGeneration ?? 0) + 1,
  );

  @override
  Future<void> startForGeneration(int generation) =>
      startForSession(_sessionGeneration, generation);

  @override
  Future<void> startForSession(
    int sessionGeneration,
    int listenGeneration,
  ) async {
    if (sessionGeneration != _sessionGeneration) return;
    startCount++;
    _currentListenGeneration = listenGeneration;
    _resultSessionGeneration = null;
    _resultListenGeneration = null;
    _partial = '';
    _final = '';
    _error = '';
    _errorCode = '';
    _statusEvent = '';
    if (delayNextStart) {
      delayNextStart = false;
      _status = SttStatus.starting;
      notifyListeners();
      return;
    }
    _status = SttStatus.listening;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _status = SttStatus.stopped;
    notifyListeners();
  }

  @override
  void pause() {}
  @override
  Future<void> resume() => start();

  void end() {
    _status = SttStatus.stopped;
    _statusEvent = 'done';
    notifyListeners();
  }

  void noMatch() {
    _status = SttStatus.stopped;
    _errorCode = 'error_no_match';
    _statusEvent = 'notListening';
    notifyListeners();
  }

  void acknowledgeListening() {
    _status = SttStatus.listening;
    notifyListeners();
  }

  void recognize(String text) {
    _final = text;
    _partial = '';
    _resultSessionGeneration = _sessionGeneration;
    _resultListenGeneration = _currentListenGeneration;
    notifyListeners();
  }

  void recognizeBeforeAcknowledgement(String text) {
    _status = SttStatus.starting;
    _final = text;
    _partial = '';
    _resultSessionGeneration = _sessionGeneration;
    _resultListenGeneration = _currentListenGeneration;
    notifyListeners();
  }

  void emitResultFromSession(
    int sessionGeneration,
    int listenGeneration,
    String text,
  ) {
    _final = text;
    _partial = '';
    _resultSessionGeneration = sessionGeneration;
    _resultListenGeneration = listenGeneration;
    notifyListeners();
  }

  @override
  void clearCurrentResult() {
    _final = '';
    _partial = '';
    _resultSessionGeneration = null;
    _resultListenGeneration = null;
  }
}

class _PcmFakeSttAdapter extends _FakeSttAdapter implements PcmInputSttAdapter {
  final List<Uint8List> pcmChunks = <Uint8List>[];

  @override
  void addPcmChunk(Uint8List pcm16LittleEndian, {required int sampleRate}) {
    expect(sampleRate, 16000);
    pcmChunks.add(Uint8List.fromList(pcm16LittleEndian));
  }
}

class _PcmFakeCapture implements PcmVoiceNoteAudioCapture {
  _PcmFakeCapture(this.path);

  final String path;
  void Function(Uint8List pcm16LittleEndian)? _onPcmChunk;
  int stopCalls = 0;
  bool started = false;
  int _fileSizeBytes = 0;

  @override
  set onPcmChunk(void Function(Uint8List pcm16LittleEndian)? callback) =>
      _onPcmChunk = callback;

  void emit(Uint8List bytes) => _onPcmChunk?.call(bytes);

  @override
  Future<void> start() async {
    final File file = File(path);
    file.writeAsBytesSync(List<int>.filled(256, 0x2a), flush: true);
    _fileSizeBytes = file.lengthSync();
    started = true;
  }

  @override
  Future<VoiceAudioSegment> stop() async {
    stopCalls++;
    return VoiceAudioSegment(
      path: path,
      duration: const Duration(seconds: 2),
      fileSizeBytes: _fileSizeBytes,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FailOnceConversationAudioStore extends LocalNoteAudioStore {
  int saveCalls = 0;

  @override
  Future<void> save(String noteId, LocalNoteAudioReference reference) async {
    saveCalls++;
    if (saveCalls == 1) throw StateError('test attachment failure');
    await super.save(noteId, reference);
  }
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
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
}

class _FakeAiClient implements ConversationAiClient {
  int requests = 0;
  int failuresRemaining = 0;
  Completer<String>? pendingReply;
  final List<List<ConversationMessage>> histories =
      <List<ConversationMessage>>[];

  @override
  Future<String> reply(List<ConversationMessage> history) async {
    requests++;
    histories.add(List<ConversationMessage>.of(history));
    if (history.isEmpty || history.last.speaker != ConversationSpeaker.user) {
      throw StateError('Conversation request must end with a user turn.');
    }
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const ConversationAiException(
        'The AI provider is busy. Please try again later.',
        code: 'edge_function',
        statusCode: 502,
      );
    }
    if (pendingReply != null) return pendingReply!.future;
    return 'A real reply from the injected AI service.';
  }
}

class _FailingSaveRepository extends InMemoryNotesRepository {
  @override
  Future<void> saveNote(Note note) async {
    throw StateError('save failed');
  }
}

Future<void> _openConversation(
  WidgetTester tester, {
  required _FakeSttAdapter stt,
  required _FakeAiClient ai,
  required ConversationSession session,
  NotesRepository? repository,
  LatestNoteCubit? latestNoteCubit,
  VoiceNoteAudioCapture Function()? voiceAudioCaptureFactory,
  LocalNoteAudioStore? localNoteAudioStore,
  bool conversationMode = true,
}) async {
  await tester.pumpWidget(
    material_ui.MaterialApp(
      theme: material_ui.ThemeData(),
      home: material_ui.Builder(
        builder: (context) => material_ui.Scaffold(
          body: material_ui.TextButton(
            onPressed: () => material_ui.Navigator.of(context).push<void>(
              material_ui.MaterialPageRoute<void>(
                builder: (_) => CreateNoteScreen(
                  sttAdapter: stt,
                  conversationSession: session,
                  conversationAiClient: ai,
                  notesRepository: repository,
                  latestNoteCubit: latestNoteCubit,
                  userId: 'user-1',
                  voiceAudioCaptureFactory: voiceAudioCaptureFactory,
                  localNoteAudioStore: localNoteAudioStore,
                ),
              ),
            ),
            child: const material_ui.Text('Open record'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open record'));
  await _pumpFrames(tester);
  if (conversationMode) {
    await tester.tap(find.text('Conversation'));
    await _pumpFrames(tester);
  }
}

Future<void> _pumpFrames(WidgetTester tester) async {
  // The animated orb continuously schedules frames, so settling is unbounded.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _startMic(WidgetTester tester) async {
  await tester.tap(find.text('Start conversation'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('Record-mode final never starts a Conversation request', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
      conversationMode: false,
    );

    await tester.tap(find.text('Start recording'));
    await _pumpFrames(tester);
    final int recordSession = stt.currentSessionGeneration!;
    final int recordListen = stt.currentListenGeneration!;
    stt.recognize('Only a Record transcript.');
    await tester.pump();
    expect(ai.requests, 0);

    await tester.tap(find.text('Stop & finish'));
    await _pumpFrames(tester);
    expect(find.text('Choose a category'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _pumpFrames(tester);

    await tester.tap(find.text('Conversation'));
    await _pumpFrames(tester);
    await _startMic(tester);
    expect(ai.requests, 0);
    expect(stt.finalText, isEmpty);

    stt.emitResultFromSession(
      recordSession,
      recordListen,
      'Late Record callback.',
    );
    await tester.pump();
    expect(ai.requests, 0);
    expect(session.messages, isEmpty);
  });

  testWidgets(
    'final received before the first listening acknowledgement is rejected',
    (
      tester,
    ) async {
      final _FakeSttAdapter stt = _FakeSttAdapter()..delayNextStart = true;
      final _FakeAiClient ai = _FakeAiClient();
      final ConversationSession session = ConversationSession(
        isConnected: true,
      );
      await _openConversation(tester, stt: stt, ai: ai, session: session);

      await tester.tap(find.text('Start conversation'));
      await tester.pump();
      expect(stt.status, SttStatus.starting);
      stt.recognizeBeforeAcknowledgement('Premature final.');
      await tester.pump();

      expect(ai.requests, 0);
      expect(session.messages, isEmpty);
      expect(stt.finalText, isEmpty);

      stt.acknowledgeListening();
      await _pumpFrames(tester);
      stt.recognize('Premature final.');
      await _pumpFrames(tester);
      expect(ai.requests, 1);
    },
  );

  testWidgets(
    'identical consecutive utterances on separate listens both submit',
    (
      tester,
    ) async {
      final _FakeSttAdapter stt = _FakeSttAdapter();
      final _FakeAiClient ai = _FakeAiClient();
      final ConversationSession session = ConversationSession(
        isConnected: true,
      );
      await _openConversation(tester, stt: stt, ai: ai, session: session);
      await _startMic(tester);

      stt.end();
      await tester.pump();
      stt.recognize('hello');
      await _pumpFrames(tester);
      expect(ai.requests, 1);
      expect(stt.status, SttStatus.listening);
      expect(stt.startCount, 2);

      stt.end();
      await tester.pump();
      stt.recognize('hello');
      await _pumpFrames(tester);
      expect(ai.requests, 2);
      expect(
        session.messages.where(
          (message) => message.speaker == ConversationSpeaker.user,
        ),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'Conversation fans captured PCM to STT and retries local audio attachment without duplicating note',
    (tester) async {
      final String path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'conversation-shared-pcm-${DateTime.now().microsecondsSinceEpoch}.wav';
      final File file = File(path);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      final _PcmFakeSttAdapter stt = _PcmFakeSttAdapter();
      final _PcmFakeCapture capture = _PcmFakeCapture(path);
      final _FakeAiClient ai = _FakeAiClient();
      final ConversationSession session = ConversationSession(
        isConnected: true,
      );
      final InMemoryNotesRepository repository = InMemoryNotesRepository();
      final LatestNoteCubit latest = LatestNoteCubit(repository: repository);
      final _FailOnceConversationAudioStore audioStore =
          _FailOnceConversationAudioStore();
      await _openConversation(
        tester,
        stt: stt,
        ai: ai,
        session: session,
        repository: repository,
        latestNoteCubit: latest,
        voiceAudioCaptureFactory: () => capture,
        localNoteAudioStore: audioStore,
      );
      await _startMic(tester);
      for (var frame = 0; frame < 30 && !capture.started; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (
        var frame = 0;
        frame < 30 && stt.status != SttStatus.listening;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(capture.started, isTrue);
      expect(stt.status, SttStatus.listening);

      final Uint8List firstChunk = Uint8List.fromList(<int>[
        0x00,
        0x00,
        0x10,
        0x00,
        0x20,
        0x00,
        0x30,
        0x00,
      ]);
      capture.emit(firstChunk);
      expect(stt.pcmChunks, hasLength(1));
      expect(stt.pcmChunks.single, orderedEquals(firstChunk));
      for (var turn = 0; turn < 3; turn++) {
        if (turn > 0) capture.emit(Uint8List.fromList(<int>[0, 0, 1, 0]));
        stt.recognize('Repeat this question');
        await _pumpFrames(tester);
        expect(ai.requests, turn + 1);
      }
      expect(
        session.messages.where(
          (message) => message.speaker == ConversationSpeaker.user,
        ),
        hasLength(3),
      );
      expect(
        session.messages.where(
          (message) => message.speaker == ConversationSpeaker.ai,
        ),
        hasLength(3),
      );
      expect(stt.startCount, 4);

      final Finder finishConversation = find.widgetWithText(
        material_ui.TextButton,
        'Finish conversation',
      );
      expect(finishConversation, findsOneWidget);
      await tester.ensureVisible(finishConversation);
      await tester.tap(finishConversation);
      await _pumpFrames(tester);
      expect(find.text('Choose a category'), findsOneWidget);
      await tester.enterText(
        find.byKey(const material_ui.Key('new-category')),
        'Ideas',
      );
      await tester.pump();
      final Finder firstSave = find.widgetWithText(
        material_ui.FilledButton,
        'Save',
      );
      tester.widget<material_ui.FilledButton>(firstSave).onPressed!.call();
      await _pumpFrames(tester);
      expect(capture.stopCalls, 1);
      expect(audioStore.saveCalls, 1);
      expect(file.existsSync(), isTrue);
      final String retainedNoteId = latest.state.latestNote!.id;

      await tester.ensureVisible(finishConversation);
      await tester.tap(finishConversation);
      await _pumpFrames(tester);
      expect(find.text('Choose a category'), findsOneWidget);
      await tester.enterText(
        find.byKey(const material_ui.Key('new-category')),
        'Ideas',
      );
      await tester.pump();
      final Finder retrySave = find.widgetWithText(
        material_ui.FilledButton,
        'Save',
      );
      tester.widget<material_ui.FilledButton>(retrySave).onPressed!.call();
      await _pumpFrames(tester);

      final List<Note> savedNotes = await repository.getNotes(
        userId: 'user-1',
      );
      expect(savedNotes, hasLength(1));
      expect(savedNotes.single.id, retainedNoteId);
      expect(audioStore.saveCalls, 2);
      expect(capture.stopCalls, 1);

      final Note reopened = (await tester.runAsync(
        () => LocalNoteAudioStore().attachToNotes(<Note>[
          Note(
            id: retainedNoteId,
            userId: 'user-1',
            title: savedNotes.single.title,
            preview: savedNotes.single.preview,
            transcript: savedNotes.single.transcript,
            createdAt: savedNotes.single.createdAt,
            conversationMessages: savedNotes.single.conversationMessages,
          ),
        ]),
      ))!.single;
      expect(reopened.localAudioPaths, <String>[path]);
      final _CapturingPlayerHandler player = _CapturingPlayerHandler();
      final PlayerHandlerNoteAudioPlaybackController controller =
          PlayerHandlerNoteAudioPlaybackController(
            note: reopened,
            handler: player,
          );
      await controller.play();
      expect(player.loadedPaths, <String>[path]);
      expect(player.playCalls, 1);
      await tester.runAsync(controller.dispose);
      await tester.pumpWidget(const material_ui.SizedBox.shrink());
    },
  );

  testWidgets('silent recognizer endings keep restarting until Stop', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(tester, stt: stt, ai: ai, session: session);
    await _startMic(tester);
    expect(stt.startCount, 1);

    for (var i = 0; i < 5; i++) {
      stt.noMatch();
      await tester.pump();
      await tester.pump();
      expect(stt.startCount, i + 2);
    }

    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stt.startCount, 6);
    expect(find.text('Start conversation'), findsOneWidget);
    expect(session.messages, isEmpty);
    expect(ai.requests, 0);
  });

  testWidgets('done before final preserves turn and supports a second turn', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
    );
    await _startMic(tester);

    stt.end();
    await _pumpFrames(tester);
    expect(session.messages, isEmpty);
    expect(find.text('Stop'), findsOneWidget);

    stt.recognize('How should I plan this project?');
    await _pumpFrames(tester);
    stt.recognize('How should I plan this project?');
    await _pumpFrames(tester);

    expect(ai.requests, 1);
    expect(
      session.messages.where((m) => m.speaker == ConversationSpeaker.user),
      hasLength(1),
    );
    expect(session.messages.last.speaker, ConversationSpeaker.ai);
    expect(
      find.text('A real reply from the injected AI service.'),
      findsOneWidget,
    );
    expect(find.text('Next turn'), findsNothing);
    expect(find.text('Ready'), findsNothing);
    expect(stt.startCount, 2);

    // A new listen may legitimately produce the same words again.
    stt.end();
    await tester.pump(const Duration(milliseconds: 900));
    stt.recognize('How should I plan this project?');
    await _pumpFrames(tester);
    expect(ai.requests, 2);
    expect(
      ai.histories.last.map((message) => message.speaker).toList(),
      <ConversationSpeaker>[
        ConversationSpeaker.user,
        ConversationSpeaker.ai,
        ConversationSpeaker.user,
      ],
    );
    expect(stt.startCount, 3);
  });

  testWidgets('failed request retains user message and Retry reuses it', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient()..failuresRemaining = 1;
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
    );
    await _startMic(tester);
    stt.recognize('Keep this question for retry.');
    await _pumpFrames(tester);

    expect(ai.requests, 1);
    expect(
      find.text('Reply failed. Tap Retry.'),
      findsOneWidget,
    );
    expect(
      session.messages.where((m) => m.speaker == ConversationSpeaker.user),
      hasLength(1),
    );
    final String failedReplyId = session.messages
        .singleWhere((m) => m.speaker == ConversationSpeaker.ai)
        .id;

    await tester.tap(find.text('Retry'));
    await _pumpFrames(tester);
    expect(ai.requests, 2);
    expect(
      session.messages.where((m) => m.speaker == ConversationSpeaker.user),
      hasLength(1),
    );
    expect(session.messages.last.speaker, ConversationSpeaker.ai);
    expect(find.text('Reply failed. Tap Retry.'), findsNothing);
    expect(
      session.messages
          .singleWhere((m) => m.speaker == ConversationSpeaker.ai)
          .id,
      failedReplyId,
    );
  });

  testWidgets('Stop while reply is pending ignores its late response', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient()
      ..pendingReply = Completer<String>();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(tester, stt: stt, ai: ai, session: session);
    await _startMic(tester);
    stt.recognize('Stop while the AI is thinking.');
    await tester.pump();

    expect(find.text('...'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await _pumpFrames(tester);
    expect(find.text('Start conversation'), findsOneWidget);
    expect(find.text('...'), findsNothing);

    ai.pendingReply!.complete('This late reply must be ignored.');
    await _pumpFrames(tester);
    expect(find.text('This late reply must be ignored.'), findsNothing);
    expect(stt.startCount, 1);
  });

  testWidgets('delayed prior stop cannot cancel the next listen', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(tester, stt: stt, ai: ai, session: session);
    await _startMic(tester);
    stt.delayNextStart = true;

    stt.recognize('First turn.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(ai.requests, 1);
    expect(stt.status, SttStatus.starting);

    // Simulate Android's late notListening/done callback from turn one.
    stt.end();
    await tester.pump();
    expect(stt.status, SttStatus.stopped);
    expect(find.text('Stop'), findsOneWidget);
    expect(session.status, isNot(ConversationStatus.error));

    stt.acknowledgeListening();
    await _pumpFrames(tester);
    expect(stt.status, SttStatus.listening);
    expect(stt.startCount, 2);

    stt.recognize('Second turn.');
    await _pumpFrames(tester);
    expect(ai.requests, 2);
    expect(
      session.messages.where((m) => m.speaker == ConversationSpeaker.user),
      hasLength(2),
    );
  });

  testWidgets('Finish saves ordered exchange and refreshes Home state', (
    tester,
  ) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    final InMemoryNotesRepository repository = InMemoryNotesRepository();
    final LatestNoteCubit latest = LatestNoteCubit(repository: repository);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
      repository: repository,
      latestNoteCubit: latest,
    );
    await _startMic(tester);
    stt.recognize('Save this conversation.');
    await _pumpFrames(tester);

    await tester.tap(find.text('Finish conversation'));
    await _pumpFrames(tester);
    expect(find.text('Choose a category'), findsOneWidget);
    await tester.enterText(
      find.byKey(const material_ui.Key('new-category')),
      'Ideas',
    );
    await tester.tap(find.text('Save'));
    await _pumpFrames(tester);

    final List<Note> saved = await repository.getNotes(userId: 'user-1');
    expect(saved, hasLength(1));
    expect(saved.single.category, 'Ideas');
    expect(saved.single.transcript, contains('User: Save this conversation.'));
    expect(saved.single.transcript, contains('AI: A real reply'));
    expect(saved.single.conversationMessages, hasLength(2));
    expect(latest.state.latestNote?.id, saved.single.id);
    expect(session.messages, isEmpty);
  });

  testWidgets('canceling Finish keeps the conversation draft', (tester) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
    );
    await _startMic(tester);
    stt.recognize('Keep this draft.');
    await _pumpFrames(tester);

    await tester.tap(find.text('Finish conversation'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Cancel'));
    await _pumpFrames(tester);
    expect(session.messages, hasLength(2));
    expect(find.text('Finish conversation'), findsOneWidget);
  });

  testWidgets('save failure keeps the exchange for retry', (tester) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient();
    final ConversationSession session = ConversationSession(isConnected: true);
    final _FailingSaveRepository repository = _FailingSaveRepository();
    final LatestNoteCubit latest = LatestNoteCubit(repository: repository);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
      repository: repository,
      latestNoteCubit: latest,
    );
    await _startMic(tester);
    stt.recognize('Keep this when saving fails.');
    await _pumpFrames(tester);

    await tester.tap(find.text('Finish conversation'));
    await _pumpFrames(tester);
    await tester.enterText(
      find.byKey(const material_ui.Key('new-category')),
      'Work',
    );
    await tester.tap(find.text('Save'));
    await _pumpFrames(tester);
    expect(session.messages, hasLength(2));
    expect(find.text('Finish conversation'), findsOneWidget);
    expect(latest.state.notes, isEmpty);
  });

  testWidgets('Finish does not discard an in-flight AI reply', (tester) async {
    final _FakeSttAdapter stt = _FakeSttAdapter();
    final _FakeAiClient ai = _FakeAiClient()
      ..pendingReply = Completer<String>();
    final ConversationSession session = ConversationSession(isConnected: true);
    await _openConversation(
      tester,
      stt: stt,
      ai: ai,
      session: session,
    );
    await _startMic(tester);
    stt.recognize('Wait for the reply before saving.');
    await tester.pump();

    expect(find.text('...'), findsOneWidget);
    final String pendingReplyId = session.messages
        .singleWhere((message) => message.isPending)
        .id;
    await tester.tap(find.text('Finish conversation'));
    await tester.pump();
    expect(
      find.text('Wait for the AI reply before finishing.'),
      findsOneWidget,
    );

    ai.pendingReply!.complete('The pending reply is preserved.');
    await _pumpFrames(tester);
    expect(find.text('The pending reply is preserved.'), findsOneWidget);
    expect(
      session.messages
          .singleWhere((message) => message.speaker == ConversationSpeaker.ai)
          .id,
      pendingReplyId,
    );
    expect(stt.status, SttStatus.listening);
    expect(stt.startCount, 2);
    expect(ai.requests, 1);
  });
}
