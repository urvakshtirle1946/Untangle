import 'dart:typed_data';

import 'package:bunpod/features/notes/models/voice_note_state.dart';
import 'package:bunpod/features/notes/pages/create_note_placeholder_page.dart';
import 'package:bunpod/features/notes/stt/stt_adapter.dart';
import 'package:bunpod/features/notes/services/voice_note_audio.dart';
import 'package:bunpod/common/theme/material_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;

class FakeSttAdapter extends SttAdapter implements PcmInputSttAdapter {
  FakeSttAdapter({this.initResult = SttInitResult.ready});
  final SttInitResult initResult;
  SttStatus _status = SttStatus.idle;
  String _error = '';
  String _partial = '';
  String _final = '';
  final List<Uint8List> pcmChunks = <Uint8List>[];
  final List<int> pcmSampleRates = <int>[];
  @override
  SttStatus get status => _status;
  @override
  String get lastError => _error;
  @override
  String get partialText => _partial;
  @override
  String get finalText => _final;
  @override
  Future<SttInitResult> initialize() async {
    if (initResult == SttInitResult.permissionDenied) {
      _error = 'Microphone permission was denied.';
    }
    _status = initResult == SttInitResult.ready
        ? SttStatus.stopped
        : SttStatus.error;
    notifyListeners();
    return initResult;
  }

  @override
  Future<void> start() async {
    _status = SttStatus.listening;
    _partial = '';
    _final = '';
    notifyListeners();
  }

  void partial(String value) {
    _partial = value;
    notifyListeners();
  }

  void finish(String value) {
    _final = value;
    _partial = '';
    notifyListeners();
  }

  void end() {
    _status = SttStatus.stopped;
    notifyListeners();
  }

  void fail(String message) {
    _error = message;
    _status = SttStatus.error;
    notifyListeners();
  }

  @override
  void pause() => end();
  @override
  Future<void> resume() => start();
  @override
  Future<void> stop() async {
    end();
  }

  @override
  void addPcmChunk(Uint8List pcm16LittleEndian, {required int sampleRate}) {
    pcmChunks.add(Uint8List.fromList(pcm16LittleEndian));
    pcmSampleRates.add(sampleRate);
  }
}

class _FakePcmCapture implements PcmVoiceNoteAudioCapture {
  void Function(Uint8List pcm16LittleEndian)? _onPcmChunk;

  @override
  set onPcmChunk(void Function(Uint8List pcm16LittleEndian)? callback) =>
      _onPcmChunk = callback;

  void emit(Uint8List bytes) => _onPcmChunk?.call(bytes);

  @override
  Future<void> start() async {}

  @override
  Future<VoiceAudioSegment> stop() async => const VoiceAudioSegment(
    path: 'fake-record.wav',
    duration: Duration(seconds: 1),
    fileSizeBytes: 32000,
  );

  @override
  Future<void> dispose() async {}
}

Widget wrap(Widget child) => MaterialApp(
  theme: MaterialThemes.light,
  home: child is CreateNoteScreen
      ? CreateNoteScreen(
          key: child.key,
          transcriptState: child.transcriptState,
          conversationSession: child.conversationSession,
          sttAdapter: child.sttAdapter,
          notesRepository: child.notesRepository,
          latestNoteCubit: child.latestNoteCubit,
          userId: child.userId,
          conversationAiClient: child.conversationAiClient,
          voiceAudioCaptureFactory: () => _FakePcmCapture(),
          localNoteAudioStore: child.localNoteAudioStore,
        )
      : child,
);

void main() {
  testWidgets('Record shares PCM with Sherpa and appends repeated segments', (
    tester,
  ) async {
    final FakeSttAdapter adapter = FakeSttAdapter();
    final TranscriptState transcript = TranscriptState(isConnected: true);
    final _FakePcmCapture capture = _FakePcmCapture();
    await tester.pumpWidget(
      MaterialApp(
        theme: MaterialThemes.light,
        home: CreateNoteScreen(
          transcriptState: transcript,
          sttAdapter: adapter,
          voiceAudioCaptureFactory: () => capture,
        ),
      ),
    );
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(adapter.status, SttStatus.listening);
    final Uint8List pcm = Uint8List(320);
    capture.emit(pcm);
    expect(adapter.pcmChunks, hasLength(1));
    expect(adapter.pcmChunks.single, pcm);
    expect(adapter.pcmSampleRates.single, 16000);
    adapter.partial('same phrase');
    await tester.pump();
    expect(transcript.displayText, 'same phrase');
    adapter.finish('same phrase');
    await tester.pump();
    adapter.finish('same phrase');
    await tester.pump();
    expect(transcript.displayText, 'same phrase');
    adapter.end();
    await tester.pump();
    await tester.pump();
    expect(adapter.status, SttStatus.listening);

    adapter.finish('same phrase');
    await tester.pump();
    expect(transcript.displayText, 'same phrase same phrase');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Record keeps recognition running after each endpoint',
    (tester) async {
      final adapter = FakeSttAdapter();
      final transcript = TranscriptState(isConnected: true);
      await tester.pumpWidget(
        wrap(
          CreateNoteScreen(transcriptState: transcript, sttAdapter: adapter),
        ),
      );
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      adapter.partial('नमस्ते दुनिया');
      await tester.pump();
      expect(transcript.displayText, 'नमस्ते दुनिया');
      adapter.finish('नमस्ते दुनिया');
      await tester.pump();
      expect(transcript.displayText, 'नमस्ते दुनिया');
      adapter.end();
      await tester.pump();
      await tester.pump();
      expect(adapter.status, SttStatus.listening);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Resume recognition'), findsNothing);
      expect(transcript.displayText, 'नमस्ते दुनिया');
      for (var restart = 0; restart < 5; restart++) {
        adapter.end();
        await tester.pump();
        await tester.pump();
        expect(adapter.status, SttStatus.listening);
      }
    },
  );

  testWidgets('permission failure keeps recording audio only', (tester) async {
    final adapter = FakeSttAdapter(initResult: SttInitResult.permissionDenied);
    final transcript = TranscriptState(isConnected: true);
    await tester.pumpWidget(
      wrap(CreateNoteScreen(transcriptState: transcript, sttAdapter: adapter)),
    );
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(transcript.isRecording, isTrue);
    expect(
      find.text(
        'Speech recognition is unavailable. Recording will continue with audio.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'finalized and manually edited transcript survives Record and Type tab switches',
    (tester) async {
      final adapter = FakeSttAdapter();
      final transcript = TranscriptState(isConnected: true)
        ..finalizeUtterance('Saved draft');
      await tester.pumpWidget(
        wrap(
          CreateNoteScreen(transcriptState: transcript, sttAdapter: adapter),
        ),
      );
      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Stop & finish'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.tap(find.text('Type'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Voice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(transcript.displayText, 'Saved draft');
      transcript.updateManualEdits('Edited by hand');
      expect(transcript.displayText, 'Edited by hand');
    },
  );

  testWidgets('Record transcript is read-only and Type remains editable', (
    tester,
  ) async {
    final adapter = FakeSttAdapter();
    await tester.pumpWidget(
      wrap(CreateNoteScreen(sttAdapter: adapter)),
    );
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final recordField = tester.widget<TextField>(find.byType(TextField).first);
    expect(recordField.readOnly, isTrue);
    expect(recordField.showCursor, isFalse);
    expect(recordField.enableInteractiveSelection, isTrue);
    expect(recordField.onChanged, isNull);
    expect(find.text('English'), findsNothing);
    expect(find.text('Hindi'), findsNothing);
    expect(find.byType(DropdownButton<dynamic>), findsNothing);

    adapter.finish('Speech only');
    await tester.pump();
    expect(find.text('Speech only'), findsOneWidget);

    await tester.tap(find.text('Stop & finish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Type'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final typeField = tester.widget<TextField>(find.byType(TextField));
    expect(typeField.readOnly, isFalse);
    // Type uses a TextEditingController; an onChanged callback is unnecessary.
    expect(typeField.onChanged, isNull);
    expect(find.text('Finish note'), findsOneWidget);
  });

  testWidgets('STT transcript text is displayed verbatim', (tester) async {
    final adapter = FakeSttAdapter();
    final transcript = TranscriptState(isConnected: true);
    await tester.pumpWidget(
      wrap(
        CreateNoteScreen(transcriptState: transcript, sttAdapter: adapter),
      ),
    );
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    adapter.partial(' नमस्ते,   world! ');
    await tester.pump();
    expect(transcript.displayText, ' नमस्ते,   world! ');

    adapter.finish(' नमस्ते,   world! ');
    await tester.pump();
    expect(transcript.displayText, ' नमस्ते,   world! ');
  });

  testWidgets(
    'Recognition errors do not stop Record capture',
    (
      tester,
    ) async {
      final adapter = FakeSttAdapter();
      await tester.pumpWidget(
        wrap(CreateNoteScreen(sttAdapter: adapter)),
      );
      expect(find.text('Listening'), findsNothing);

      await tester.tap(find.text('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(adapter.status, SttStatus.listening);
      expect(find.text('Listening'), findsOneWidget);

      adapter.fail('Network recognition failed');
      await tester.pump();
      expect(find.text('Recognition error'), findsOneWidget);
      expect(find.text('Stop & finish'), findsOneWidget);
      expect(find.text('Resume recognition'), findsOneWidget);
    },
  );
}
