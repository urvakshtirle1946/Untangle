/// Native [SttAdapter] backed by the `speech_to_text` plugin.
///
/// Uses the default language configured by the device recognizer.
/// Reports genuine states: listening, stopped-by-platform, error.
/// No hidden auto-restart loops.
library;

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'stt_adapter.dart';

class NativeSttAdapter extends SttAdapter {
  NativeSttAdapter() : _stt = SpeechToText();

  final SpeechToText _stt;

  @override
  SttStatus get status => _status;
  SttStatus _status = SttStatus.idle;

  @override
  String get lastError => _lastError;
  String _lastError = '';

  @override
  String get partialText => _partialText;
  String _partialText = '';

  @override
  String get finalText => _finalText;
  String _finalText = '';

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<SttInitResult> initialize() async {
    _lastError = '';

    bool ok = false;
    try {
      ok = await _stt.initialize(
        onError: _onError,
        onStatus: _onStatus,
      );
    } catch (e) {
      _lastError = e.toString();
      _setStatus(SttStatus.error);
      return SttInitResult.failed;
    }

    if (!ok) {
      // speech_to_text returns false when the recognizer is unavailable.
      // Permission denial also surfaces this way on some devices.
      if (await _stt.hasPermission == false) {
        return SttInitResult.permissionDenied;
      }
      return SttInitResult.notAvailable;
    }

    _setStatus(SttStatus.stopped);
    notifyListeners();
    return SttInitResult.ready;
  }

  @override
  Future<void> start() async {
    if (_status == SttStatus.listening) return;
    _partialText = '';
    _finalText = '';
    _lastError = '';

    _setStatus(SttStatus.starting);
    notifyListeners();
    await _stt.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
      ),
    );
  }

  @override
  void pause() {
    if (_status != SttStatus.listening) return;
    _stt.stop();
    _setStatus(SttStatus.paused);
  }

  @override
  Future<void> resume() async {
    if (_status != SttStatus.paused) return;
    await start();
  }

  @override
  Future<void> stop() async {
    await _stt.stop();
    _partialText = '';
    _setStatus(SttStatus.stopped);
  }

  @override
  void dispose() {
    _stt.cancel();
    super.dispose();
  }

  // ── Private callbacks ──────────────────────────────────────────────────────

  void _onResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      _finalText = result.recognizedWords;
      _partialText = '';
      _setStatus(SttStatus.stopped); // Platform ended the utterance.
    } else {
      _partialText = result.recognizedWords;
    }
    notifyListeners();
  }

  void _onError(SpeechRecognitionError error) {
    // 'error_no_match' and 'error_speech_timeout' are normal platform endings
    // (user paused / silence). Treat them as stopped rather than fatal errors
    // so the UI can offer Resume rather than an error message.
    const Set<String> silenceErrors = <String>{
      'error_no_match',
      'error_speech_timeout',
    };
    if (silenceErrors.contains(error.errorMsg)) {
      _setStatus(SttStatus.stopped);
    } else {
      _lastError = error.errorMsg;
      _setStatus(SttStatus.error);
    }
    notifyListeners();
  }

  void _onStatus(String status) {
    if (status == 'listening' && _status != SttStatus.error) {
      _setStatus(SttStatus.listening);
      notifyListeners();
      return;
    }
    if (status == 'notListening' || status == 'done') {
      if (_status == SttStatus.listening) {
        _setStatus(SttStatus.stopped);
        notifyListeners();
      }
    }
  }

  void _setStatus(SttStatus s) {
    _status = s;
  }
}
