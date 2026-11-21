import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as native_stt;
import 'package:flutter/services.dart';

import 'stt_adapter.dart';

/// Native system recognizer adapter. Recognition availability and processing
/// behavior are provided by Android's configured speech recognition service.
class SpeechToTextAdapter extends SttAdapter {
  SpeechToTextAdapter({
    native_stt.SpeechToText? speech,
    this.soundLevelDiagnostic,
  }) : _speech = speech ?? native_stt.SpeechToText();

  final native_stt.SpeechToText _speech;
  final void Function(double level)? soundLevelDiagnostic;
  static SpeechToTextAdapter? _callbackOwner;
  SttStatus _status = SttStatus.idle;
  String _lastError = '';
  String _lastErrorCode = '';
  String _lastStatusEvent = '';
  String _partialText = '';
  String _finalText = '';
  int _sessionGeneration = 0;
  int? _currentListenGeneration;
  int? _resultSessionGeneration;
  int? _resultListenGeneration;
  Object? _activeListenToken;
  bool _disposed = false;
  Completer<void>? _stopCompleter;
  Completer<void>? _startCompleter;
  Future<void>? _stopInFlight;
  int _listenGeneration = 0;
  bool _activeListen = false;
  bool _listenAcknowledged = false;
  bool _doneAcknowledged = false;
  bool _notListeningSeen = false;
  bool _startRequested = false;
  bool _stopRequested = false;
  SttDiagnosticLogger? _diagnosticLogger;
  SttListenGenerationProvider? _listenGenerationProvider;

  @override
  void setDiagnosticLogger(
    SttDiagnosticLogger? logger, {
    SttListenGenerationProvider? listenGenerationProvider,
  }) {
    _diagnosticLogger = logger;
    _listenGenerationProvider = listenGenerationProvider;
  }

  @override
  SttStatus get status => _status;
  @override
  String get lastError => _lastError;
  @override
  String get lastErrorCode => _lastErrorCode;
  @override
  String get lastStatusEvent => _lastStatusEvent;
  @override
  String get partialText => _partialText;
  @override
  String get finalText => _finalText;

  @override
  int? get currentSessionGeneration => _sessionGeneration;
  @override
  int? get currentListenGeneration => _currentListenGeneration;
  @override
  int? get resultSessionGeneration => _resultSessionGeneration;
  @override
  int? get resultListenGeneration => _resultListenGeneration;

  @override
  int beginSession() {
    _sessionGeneration++;
    _detachCurrentListen();
    _startRequested = false;
    _stopRequested = false;
    _doneAcknowledged = true;
    _notListeningSeen = false;
    _clearCurrentResult();
    _lastError = '';
    _lastErrorCode = '';
    return _sessionGeneration;
  }

  @override
  void clearCurrentResult() => _clearCurrentResult();

  void _clearCurrentResult() {
    _partialText = '';
    _finalText = '';
    _resultSessionGeneration = null;
    _resultListenGeneration = null;
  }

  void _detachCurrentListen() {
    _activeListenToken = null;
    _activeListen = false;
    _listenAcknowledged = false;
    _currentListenGeneration = null;
  }

  void _setStatus(SttStatus status) {
    _status = status;
    _notifyListenersSafely();
  }

  void _notifyListenersSafely() {
    if (!_disposed) notifyListeners();
  }

  void _diag(String event, {int? listenGeneration}) {
    _diagnosticLogger?.call(
      event,
      listenGeneration: listenGeneration ?? _listenGenerationProvider?.call(),
    );
  }

  String _userError(String code) {
    final String normalized = code.toLowerCase();
    if (normalized.contains('no_match')) {
      return 'No speech was recognized. Tap Resume to try again.';
    }
    if (normalized.contains('speech_timeout') ||
        normalized.contains('timeout')) {
      return 'Recognition stopped after silence or a timeout. Tap Resume to continue.';
    }
    if (normalized.contains('language_not_supported') ||
        normalized.contains('language_unavailable')) {
      return 'The system recognizer does not support its default language.';
    }
    if (normalized.contains('permission')) {
      return 'Microphone permission is required for speech recognition.';
    }
    return 'Speech recognition failed ($code). Tap Resume to try again.';
  }

  @override
  Future<SttInitResult> initialize() async {
    _lastError = '';
    _lastErrorCode = '';
    _callbackOwner = this;
    try {
      final bool ready = await _speech.initialize(
        options: <native_stt.SpeechConfigOption>[
          native_stt.SpeechToText.androidNoBluetooth,
        ],
        // speech_to_text stores these callbacks on its process-wide singleton
        // and does not replace them after a successful initialize. Install
        // static dispatch closures so later adapters receive current events.
        onError: (error) =>
            SpeechToTextAdapter._callbackOwner?._onGlobalError(error),
        onStatus: (status) =>
            SpeechToTextAdapter._callbackOwner?._onGlobalStatus(status),
      );
      if (!ready) {
        final bool permission = await _speech.hasPermission;
        _lastError = permission
            ? 'No speech recognition service is available.'
            : 'Microphone permission was denied.';
        _setStatus(SttStatus.error);
        return permission
            ? SttInitResult.notAvailable
            : SttInitResult.permissionDenied;
      }
      _setStatus(SttStatus.stopped);
      return SttInitResult.ready;
    } catch (error) {
      _lastError = error.toString();
      _setStatus(SttStatus.error);
      try {
        final bool allowed = await _speech.hasPermission;
        return allowed ? SttInitResult.failed : SttInitResult.permissionDenied;
      } catch (_) {
        return SttInitResult.failed;
      }
    }
  }

  @override
  Future<void> start() =>
      _startForSession(_sessionGeneration, _listenGeneration + 1);

  @override
  Future<void> startForGeneration(int generation) =>
      _startForSession(_sessionGeneration, generation);

  @override
  Future<void> startForSession(int sessionGeneration, int listenGeneration) =>
      _startForSession(sessionGeneration, listenGeneration);

  Future<void> _startForSession(
    int sessionGeneration,
    int generation,
  ) async {
    if (sessionGeneration != _sessionGeneration) {
      _diag(
        'event=listen_call_skipped reason=stale_session_generation',
        listenGeneration: generation,
      );
      return;
    }
    if (_status == SttStatus.listening || _status == SttStatus.starting) {
      _diag(
        'event=listen_call_skipped reason=already_active',
        listenGeneration: generation,
      );
      return;
    }
    if (_listenAcknowledged && !_doneAcknowledged) {
      _diag(
        'event=listen_call_skipped reason=prior_listen_not_done',
        listenGeneration: generation,
      );
      return;
    }
    final int listenGeneration = generation;
    _listenGeneration = listenGeneration;
    _currentListenGeneration = listenGeneration;
    _clearCurrentResult();
    final Object listenToken = Object();
    _activeListenToken = listenToken;
    final Completer<void> startCompletion = Completer<void>();
    _startCompleter = startCompletion;
    _startRequested = true;
    _listenAcknowledged = false;
    _doneAcknowledged = false;
    _notListeningSeen = false;
    _stopRequested = false;
    _activeListen = true;
    _partialText = '';
    _finalText = '';
    _lastError = '';
    _lastErrorCode = '';
    _lastStatusEvent = '';
    _setStatus(SttStatus.starting);
    _diag(
      'event=listen_call_start plugin_isListening=${_speech.isListening}',
      listenGeneration: listenGeneration,
    );
    final Stopwatch listenCallTimer = Stopwatch()..start();
    try {
      await _speech.listen(
        listenOptions: native_stt.SpeechListenOptions(
          partialResults: true,
          onDevice: false,
        ),
        onSoundLevelChange: soundLevelDiagnostic,
        onResult: (result) {
          final bool finalAfterDone =
              result.finalResult &&
              _doneAcknowledged &&
              _lastStatusEvent == native_stt.SpeechToText.doneStatus;
          _diag(
            'event=result_arrived isFinal=${result.finalResult} plugin_isListening=${_speech.isListening} callback_scope=per_listen',
            listenGeneration: listenGeneration,
          );
          if (!identical(listenToken, _activeListenToken) ||
              sessionGeneration != _sessionGeneration ||
              listenGeneration != _listenGeneration ||
              (!_activeListen && !_stopRequested && !finalAfterDone)) {
            _diag(
              'event=result_callback_rejected reason=stale_session_or_listen_generation',
              listenGeneration: listenGeneration,
            );
            return;
          }
          if (!_listenAcknowledged) {
            _diag(
              'event=result_callback_rejected reason=listen_not_acknowledged',
              listenGeneration: listenGeneration,
            );
            return;
          }
          _resultSessionGeneration = sessionGeneration;
          _resultListenGeneration = listenGeneration;
          if (result.finalResult) {
            _finalText = result.recognizedWords;
            _partialText = '';
            // A final result closes this per-listen callback. The recognizer
            // may still deliver global status events while stop() completes.
            _activeListenToken = null;
          } else {
            _partialText = result.recognizedWords;
          }
          _notifyListenersSafely();
        },
      );
      _diag(
        'event=listen_call_complete plugin_isListening=${_speech.isListening} elapsed_ms=${listenCallTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
      if (_speech.isListening && _status != SttStatus.error) {
        _listenAcknowledged = true;
        _setStatus(SttStatus.listening);
      }
    } catch (error) {
      final String code = error is PlatformException
          ? error.code
          : error.runtimeType.toString();
      _diag(
        'event=listen_call_exception code=$code plugin_isListening=${_speech.isListening} elapsed_ms=${listenCallTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
      _startRequested = false;
      _listenAcknowledged = false;
      _lastError = _userError(code);
      _lastErrorCode = code;
      _activeListen = false;
      _activeListenToken = null;
      _currentListenGeneration = null;
      _doneAcknowledged = true;
      _setStatus(SttStatus.error);
    } finally {
      if (!startCompletion.isCompleted) startCompletion.complete();
      if (identical(_startCompleter, startCompletion)) _startCompleter = null;
    }
  }

  @override
  void pause() {
    unawaited(stop());
  }

  @override
  Future<void> resume() => start();

  @override
  Future<void> stop() {
    final Future<void>? activeStop = _stopInFlight;
    if (activeStop != null) {
      _diag(
        'event=stop_call_joined_in_flight',
        listenGeneration: _listenGeneration,
      );
      return activeStop;
    }
    final Future<void> operation = _stopInternal();
    _stopInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_stopInFlight, operation)) _stopInFlight = null;
    });
  }

  Future<void> _stopInternal() async {
    final int listenGeneration = _listenGeneration;
    final Stopwatch stopTimer = Stopwatch()..start();
    _diag(
      'event=stop_call_start plugin_isListening=${_speech.isListening}',
      listenGeneration: listenGeneration,
    );
    _stopRequested = true;
    final Completer<void>? starting = _startCompleter;
    if (starting != null) await starting.future;
    if (_doneAcknowledged ||
        (!_listenAcknowledged &&
            !_speech.isListening &&
            _status != SttStatus.starting)) {
      _startRequested = false;
      _setStatus(SttStatus.stopped);
      _diag(
        'event=stop_call_complete plugin_isListening=${_speech.isListening} elapsed_ms=${stopTimer.elapsedMilliseconds} already_idle=true',
        listenGeneration: listenGeneration,
      );
      _detachCurrentListen();
      _stopRequested = false;
      return;
    }
    if (!_speech.isListening && _status != SttStatus.starting) {
      _startRequested = false;
      _listenAcknowledged = false;
      _doneAcknowledged = true;
      _setStatus(SttStatus.stopped);
      _diag(
        'event=stop_call_complete plugin_isListening=false already_stopped=true elapsed_ms=${stopTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
      _detachCurrentListen();
      _stopRequested = false;
      return;
    }
    final Completer<void> completion = Completer<void>();
    _stopCompleter = completion;
    _startRequested = false;
    try {
      if (_speech.isListening) await _speech.stop();
      if (!_speech.isListening && !_doneAcknowledged) {
        // A recognizer that has already stopped may omit `done`, especially
        // after no-match or a platform timeout. Do not wait for that callback.
        _startRequested = false;
        _listenAcknowledged = false;
        _doneAcknowledged = true;
        _completeStopWaiter();
      }
      if (!_doneAcknowledged && _speech.isListening) {
        await completion.future.timeout(const Duration(seconds: 3));
      }
      _setStatus(SttStatus.stopped);
      _diag(
        'event=stop_call_complete plugin_isListening=${_speech.isListening} elapsed_ms=${stopTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
    } on TimeoutException {
      _diag(
        'event=stop_call_exception code=done_timeout plugin_isListening=${_speech.isListening} elapsed_ms=${stopTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
      await _cancelAfterStopFailure();
      _lastError = 'The recognizer did not return its final result. Your transcript is kept.';
      _lastErrorCode = 'done_timeout';
      _setStatus(SttStatus.error);
    } catch (error) {
      final String code = error is PlatformException
          ? error.code
          : error.runtimeType.toString();
      _diag(
        'event=stop_call_exception code=$code plugin_isListening=${_speech.isListening} elapsed_ms=${stopTimer.elapsedMilliseconds}',
        listenGeneration: listenGeneration,
      );
      await _cancelAfterStopFailure();
      _lastError = _userError(
        code,
      );
      _lastErrorCode = code;
      _setStatus(SttStatus.error);
    } finally {
      if (identical(_stopCompleter, completion)) _stopCompleter = null;
      if (_doneAcknowledged) _listenAcknowledged = false;
      if (!_speech.isListening) _detachCurrentListen();
      _stopRequested = false;
    }
  }

  void _onGlobalError(dynamic error) {
    final String code = error.errorMsg.toString();
    final bool permanent = error.permanent == true;
    _diag(
      'event=plugin_error callback_scope=initialize_global source_listen_generation=unknown raw_code=$code permanent=$permanent plugin_isListening=${_speech.isListening}',
      listenGeneration: _listenGeneration,
    );
    if (_disposed || !identical(_callbackOwner, this)) return;
    final bool hasCurrentListen =
        _startRequested ||
        _listenAcknowledged ||
        _stopCompleter != null ||
        (_notListeningSeen && _doneAcknowledged && _activeListen);
    if (!hasCurrentListen) {
      _diag(
        'event=plugin_error_ignored reason=no_current_listen',
        listenGeneration: _listenGeneration,
      );
      return;
    }

    final bool noMatch = code.toLowerCase().contains('error_no_match');
    if (noMatch && _startRequested && !_listenAcknowledged) {
      _diag(
        'event=plugin_error_ignored reason=unacknowledged_listen',
        listenGeneration: _listenGeneration,
      );
      return;
    }
    _lastErrorCode = code;
    _lastError = _userError(code);
    _startRequested = false;
    _listenAcknowledged = false;
    _activeListen = false;
    _activeListenToken = null;
    _currentListenGeneration = null;
    _doneAcknowledged = true;
    _notListeningSeen = false;
    _completeStopWaiter();
    _setStatus(noMatch ? SttStatus.stopped : SttStatus.error);
  }

  void _onGlobalStatus(String status) {
    _lastStatusEvent = status;
    _diag(
      'event=plugin_status callback_scope=initialize_global source_listen_generation=unknown raw_status=$status plugin_isListening=${_speech.isListening}',
      listenGeneration: _listenGeneration,
    );
    if (_disposed || !identical(_callbackOwner, this)) return;
    if (status == native_stt.SpeechToText.listeningStatus) {
      if (!_startRequested || !_speech.isListening) {
        _diag(
          'event=plugin_status_ignored reason=no_current_listen',
          listenGeneration: _listenGeneration,
        );
        return;
      }
      _listenAcknowledged = true;
      if (_status != SttStatus.error && !_stopRequested) {
        _setStatus(SttStatus.listening);
      }
      return;
    }
    if (status != native_stt.SpeechToText.doneStatus &&
        status != native_stt.SpeechToText.notListeningStatus) {
      return;
    }
    final bool doneAfterNotListening =
        status == native_stt.SpeechToText.doneStatus &&
        _notListeningSeen &&
        _doneAcknowledged &&
        _activeListen;
    if (_speech.isListening ||
        (_startRequested && !_listenAcknowledged) ||
        (!_startRequested &&
            !_listenAcknowledged &&
            _stopCompleter == null &&
            !doneAfterNotListening)) {
      _diag(
        'event=plugin_status_ignored reason=stale_end_callback',
        listenGeneration: _listenGeneration,
      );
      return;
    }
    _startRequested = false;
    _doneAcknowledged = true;
    if (status == native_stt.SpeechToText.doneStatus) {
      _activeListen = false;
      _notListeningSeen = false;
    } else {
      _notListeningSeen = true;
    }
    _completeStopWaiter();
    if (_status != SttStatus.error) _setStatus(SttStatus.stopped);
  }

  void _completeStopWaiter() {
    final Completer<void>? completer = _stopCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _cancelAfterStopFailure() async {
    bool canceled = false;
    try {
      await _speech.cancel();
      canceled = true;
    } catch (_) {
      canceled = !_speech.isListening;
    }
    if (canceled) {
      _startRequested = false;
      _listenAcknowledged = false;
      _doneAcknowledged = true;
      _activeListen = false;
      _completeStopWaiter();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_callbackOwner, this)) _callbackOwner = null;
    _listenGeneration++;
    _detachCurrentListen();
    _completeStopWaiter();
    super.dispose();
  }
}
