/// Abstract interface for speech-to-text adapters.
///
/// Implementations must be swappable (e.g. speech_to_text, Whisper,
/// sherpa-onnx) without changing the calling UI code.
library;

import 'package:flutter/foundation.dart';

typedef SttDiagnosticLogger = void Function(
  String event, {
  int? listenGeneration,
});
typedef SttListenGenerationProvider = int Function();

// ─────────────────────────────────────────────────────────────────────────────
// Data types
// ─────────────────────────────────────────────────────────────────────────────

/// Status of the STT engine.
enum SttStatus {
  /// Not yet initialised.
  idle,

  /// Microphone open and actively listening.
  listening,

  /// The listen request is underway, awaiting the platform listening callback.
  starting,

  /// Microphone muted / paused by the user.
  paused,

  /// Recognizer stopped (silence timeout, platform limit or explicit stop).
  stopped,

  /// A non-recoverable error occurred during this session.
  error,
}

/// Result of a single `initialize()` call.
enum SttInitResult {
  /// Ready to start recognition.
  ready,

  /// Microphone permission was denied by the user.
  permissionDenied,

  /// The device has no recognition engine installed.
  notAvailable,

  /// Some other failure; see [SttAdapter.lastError].
  failed,
}

// ─────────────────────────────────────────────────────────────────────────────
// Interface
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal, replaceable STT contract consumed by the Record tab UI.
abstract class SttAdapter extends ChangeNotifier {
  /// Starts a new owner session and returns its adapter-local generation.
  /// Results from earlier sessions must no longer be exposed to listeners.
  int beginSession() => 0;

  int? get currentSessionGeneration => null;
  int? get currentListenGeneration => null;
  int? get resultSessionGeneration => null;
  int? get resultListenGeneration => null;

  /// Discards a result that was delivered before the current listen was ready.
  void clearCurrentResult() {}

  /// Optional diagnostic hook. The default is a no-op for injected adapters.
  void setDiagnosticLogger(
    SttDiagnosticLogger? logger, {
    SttListenGenerationProvider? listenGenerationProvider,
  }) {}

  /// Current engine status.
  SttStatus get status;

  /// Last human-readable error message, or empty string.
  String get lastError;

  /// Raw recognizer error code for state-machine decisions, or empty string.
  String get lastErrorCode => '';

  /// Most recent global plugin status, or empty string when unavailable.
  String get lastStatusEvent => '';

  /// Partial (in-progress) recognition text for the current utterance.
  String get partialText;

  /// Most recently finalized utterance text.
  String get finalText;

  /// Request microphone permission and prepare the recognition engine.
  ///
  /// Must be called once before [start]. Permission is only requested when the
  /// user taps "Start recording" – never on screen load.
  Future<SttInitResult> initialize();

  /// Begin recognition using the device recognizer's default language.
  Future<void> start();

  /// Begin recognition with a caller-owned generation for correlated
  /// diagnostics. Adapters that do not track generations may use [start].
  Future<void> startForGeneration(int generation) => start();

  /// Begin recognition correlated to an owner session and listen generation.
  Future<void> startForSession(int sessionGeneration, int listenGeneration) =>
      startForGeneration(listenGeneration);

  /// Mute the microphone without ending the session.
  void pause();

  /// Resume after [pause].
  Future<void> resume();

  /// End the session and release the microphone.
  Future<void> stop();
}

/// Optional contract for recognizers that consume PCM provided by the app's
/// single microphone capture stream instead of opening their own microphone.
abstract interface class PcmInputSttAdapter {
  void addPcmChunk(Uint8List pcm16LittleEndian, {required int sampleRate});
}
