import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'stt_adapter.dart';

/// On-device Conversation recognizer. The app-owned record PCM stream calls
/// [addPcmChunk], so this adapter never opens a microphone of its own.
class SherpaStreamingSttAdapter extends SttAdapter
    implements PcmInputSttAdapter {
  static const int inputSampleRate = 16000;
  static const String _assetDirectory =
      'assets/models/sherpa_onnx_streaming_zipformer_en_int8';
  static const List<String> _modelFiles = <String>[
    'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    'decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    'tokens.txt',
    'bpe.model',
  ];
  static const Map<String, int> _expectedAssetSizes = <String, int>{
    'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx': 71083163,
    'decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx': 1307236,
    'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx': 259335,
    'tokens.txt': 5048,
    'bpe.model': 244865,
  };

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  SttStatus _status = SttStatus.idle;
  String _lastError = '';
  String _lastErrorCode = '';
  String _partialText = '';
  String _finalText = '';
  int _sessionGeneration = 0;
  int _listenGeneration = 0;
  int? _currentListenGeneration;
  int? _resultSessionGeneration;
  int? _resultListenGeneration;
  int? _activeSampleRate;
  bool _activeListen = false;
  bool _disposed = false;
  int _pcmChunkCount = 0;
  int _pcmSamplesFed = 0;
  int _pcmNonzeroSamples = 0;
  int _pcmPeakAbs = 0;
  int _pcmFirstChunkBytes = 0;
  int _ignoredInactiveChunks = 0;
  double _pcmSumSquares = 0;
  SttDiagnosticLogger? _diagnosticLogger;
  SttListenGenerationProvider? _listenGenerationProvider;

  @override
  SttStatus get status => _status;
  @override
  String get lastError => _lastError;
  @override
  String get lastErrorCode => _lastErrorCode;
  @override
  String get lastStatusEvent => _status == SttStatus.listening
      ? 'listening'
      : _status == SttStatus.stopped
      ? 'notListening'
      : '';
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
  void setDiagnosticLogger(
    SttDiagnosticLogger? logger, {
    SttListenGenerationProvider? listenGenerationProvider,
  }) {
    _diagnosticLogger = logger;
    _listenGenerationProvider = listenGenerationProvider;
  }

  @override
  int beginSession() {
    _sessionGeneration++;
    _activeListen = false;
    _currentListenGeneration = null;
    _clearResult();
    _lastError = '';
    _lastErrorCode = '';
    return _sessionGeneration;
  }

  void _diag(String event, {int? generation}) {
    _diagnosticLogger?.call(
      event,
      listenGeneration: generation ?? _listenGenerationProvider?.call(),
    );
  }

  void _setStatus(SttStatus value) {
    _status = value;
    if (!_disposed) notifyListeners();
  }

  void _clearResult() {
    _partialText = '';
    _finalText = '';
    _resultSessionGeneration = null;
    _resultListenGeneration = null;
  }

  void _resetPcmDiagnostics() {
    _pcmChunkCount = 0;
    _pcmSamplesFed = 0;
    _pcmNonzeroSamples = 0;
    _pcmPeakAbs = 0;
    _pcmFirstChunkBytes = 0;
    _ignoredInactiveChunks = 0;
    _pcmSumSquares = 0;
  }

  void _logPcmSummary(String reason) {
    final double rms = _pcmSamplesFed == 0
        ? 0
        : math.sqrt(_pcmSumSquares / _pcmSamplesFed) / 32768;
    _diag(
      'event=pcm_input_summary reason=$reason listen_generation=$_listenGeneration chunks=$_pcmChunkCount first_chunk_bytes=$_pcmFirstChunkBytes samples_fed=$_pcmSamplesFed nonzero_samples=$_pcmNonzeroSamples peak_abs=$_pcmPeakAbs rms_normalized=${rms.toStringAsFixed(6)} ignored_inactive_chunks=$_ignoredInactiveChunks',
    );
  }

  @override
  void clearCurrentResult() => _clearResult();

  @override
  Future<SttInitResult> initialize() async {
    _lastError = '';
    _lastErrorCode = '';
    try {
      final Directory modelDirectory = await _copyModelAssets();
      sherpa.initBindings();
      final String encoder = _path(
        modelDirectory,
        _modelFiles[0],
      );
      final String decoder = _path(
        modelDirectory,
        _modelFiles[1],
      );
      final String joiner = _path(
        modelDirectory,
        _modelFiles[2],
      );
      final String tokens = _path(
        modelDirectory,
        _modelFiles[3],
      );
      final String bpe = _path(
        modelDirectory,
        _modelFiles[4],
      );
      _recognizer ??= sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: encoder,
              decoder: decoder,
              joiner: joiner,
            ),
            tokens: tokens,
            numThreads: 2,
            provider: 'cpu',
            debug: false,
            modelType: 'zipformer2',
            modelingUnit: 'bpe',
            bpeVocab: bpe,
          ),
          decodingMethod: 'greedy_search',
          enableEndpoint: true,
          rule1MinTrailingSilence: 2.4,
          rule2MinTrailingSilence: 1.2,
          // Rule 3 ends an utterance once its duration exceeds this value;
          // 0.3 seconds caused every listen generation to endpoint immediately.
          rule3MinUtteranceLength: 20.0,
        ),
      );
      _setStatus(SttStatus.stopped);
      return SttInitResult.ready;
    } catch (error) {
      _lastErrorCode = 'error_sherpa_initialize';
      _lastError = 'On-device speech recognition could not initialize.';
      _diag(
        'event=recognizer_initialize_failed error_type=${error.runtimeType}',
      );
      _setStatus(SttStatus.error);
      return SttInitResult.failed;
    }
  }

  Future<Directory> _copyModelAssets() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory directory = Directory(
      '${support.path}${Platform.pathSeparator}untangle_sherpa_en_int8',
    );
    await directory.create(recursive: true);
    for (final String name in _modelFiles) {
      final File file = File(_path(directory, name));
      final int expectedLength = _expectedAssetSizes[name]!;
      if (await file.exists() && await file.length() == expectedLength) {
        continue;
      }
      if (await file.exists()) await file.delete();
      final ByteData data = await rootBundle.load('$_assetDirectory/$name');
      final File temporary = File('${file.path}.partial');
      await temporary.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      if (await temporary.length() != expectedLength) {
        await temporary.delete();
        throw StateError('A packaged on-device model file is incomplete.');
      }
      await temporary.rename(file.path);
    }
    return directory;
  }

  String _path(Directory directory, String name) =>
      '${directory.path}${Platform.pathSeparator}$name';

  @override
  Future<void> start() =>
      startForSession(_sessionGeneration, _listenGeneration + 1);

  @override
  Future<void> startForGeneration(int generation) =>
      startForSession(_sessionGeneration, generation);

  @override
  Future<void> startForSession(
    int sessionGeneration,
    int listenGeneration,
  ) async {
    if (sessionGeneration != _sessionGeneration) return;
    final sherpa.OnlineRecognizer? recognizer = _recognizer;
    if (recognizer == null) {
      _lastErrorCode = 'error_sherpa_not_initialized';
      _lastError = 'On-device speech recognition is not initialized.';
      _setStatus(SttStatus.error);
      return;
    }
    if (_activeListen) return;
    _listenGeneration = listenGeneration;
    _currentListenGeneration = listenGeneration;
    _clearResult();
    _resetPcmDiagnostics();
    _lastError = '';
    _lastErrorCode = '';
    _activeSampleRate = inputSampleRate;
    _stream?.free();
    _stream = recognizer.createStream();
    _activeListen = true;
    _setStatus(SttStatus.listening);
    _diag('event=pcm_listen_started sample_rate=$inputSampleRate channels=1');
  }

  @override
  void addPcmChunk(Uint8List pcm16LittleEndian, {required int sampleRate}) {
    if (pcm16LittleEndian.isEmpty) return;
    if (!_activeListen) {
      _ignoredInactiveChunks++;
      if (_ignoredInactiveChunks == 1) {
        _diag(
          'event=pcm_chunk_ignored reason=recognizer_inactive bytes=${pcm16LittleEndian.length} listen_generation=$_listenGeneration',
        );
      }
      return;
    }
    if (sampleRate != inputSampleRate || sampleRate != _activeSampleRate) {
      _logPcmSummary('unsupported_sample_rate');
      _fail('error_pcm_sample_rate', 'Unsupported microphone sample rate.');
      return;
    }
    final sherpa.OnlineRecognizer? recognizer = _recognizer;
    final sherpa.OnlineStream? stream = _stream;
    if (recognizer == null || stream == null) return;
    try {
      final int sampleCount = pcm16LittleEndian.length ~/ 2;
      final Float32List samples = Float32List(sampleCount);
      final ByteData data = ByteData.sublistView(pcm16LittleEndian);
      var chunkNonzeroSamples = 0;
      var chunkPeakAbs = 0;
      var chunkSumSquares = 0.0;
      for (var index = 0; index < sampleCount; index++) {
        final int sample = data.getInt16(index * 2, Endian.little);
        final int absolute = sample.abs();
        samples[index] = sample / 32768.0;
        if (absolute > chunkPeakAbs) chunkPeakAbs = absolute;
        if (sample != 0) chunkNonzeroSamples++;
        chunkSumSquares += sample * sample;
      }
      stream.acceptWaveform(samples: samples, sampleRate: inputSampleRate);
      _pcmChunkCount++;
      _pcmSamplesFed += sampleCount;
      _pcmNonzeroSamples += chunkNonzeroSamples;
      if (chunkPeakAbs > _pcmPeakAbs) _pcmPeakAbs = chunkPeakAbs;
      _pcmSumSquares += chunkSumSquares;
      if (_pcmFirstChunkBytes == 0) {
        _pcmFirstChunkBytes = pcm16LittleEndian.length;
        _diag(
          'event=pcm_first_chunk_fed bytes=$_pcmFirstChunkBytes samples=$sampleCount listen_generation=$_listenGeneration',
        );
      }
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final sherpa.OnlineRecognizerResult result = recognizer.getResult(stream);
      if (result.text != _partialText) {
        _partialText = result.text;
        if (_partialText.isNotEmpty) {
          _resultSessionGeneration = _sessionGeneration;
          _resultListenGeneration = _listenGeneration;
        }
        if (!_disposed) notifyListeners();
      }
      if (recognizer.isEndpoint(stream)) {
        _finalizeCurrentTurn(result.text, reason: 'sherpa_endpoint');
      }
    } catch (error) {
      _logPcmSummary('sherpa_decode_error');
      _fail('error_sherpa_decode', 'On-device speech recognition failed.');
      _diag('event=pcm_decode_failed error_type=${error.runtimeType}');
    }
  }

  void _finalizeCurrentTurn(String text, {required String reason}) {
    _logPcmSummary(reason);
    _activeListen = false;
    final String finalized = text.trim();
    if (finalized.isNotEmpty) {
      _finalText = finalized;
      _partialText = '';
      _resultSessionGeneration = _sessionGeneration;
      _resultListenGeneration = _listenGeneration;
    }
    _setStatus(SttStatus.stopped);
    _diag(
      'event=pcm_turn_finalized has_result=${finalized.isNotEmpty} reason=$reason listen_generation=$_listenGeneration',
    );
  }

  void _fail(String code, String message) {
    _activeListen = false;
    _lastErrorCode = code;
    _lastError = message;
    _setStatus(SttStatus.error);
  }

  @override
  Future<void> stop() async {
    final sherpa.OnlineRecognizer? recognizer = _recognizer;
    final sherpa.OnlineStream? stream = _stream;
    if (_activeListen && recognizer != null && stream != null) {
      try {
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        final String result = recognizer.getResult(stream).text.trim();
        _finalizeCurrentTurn(result, reason: 'explicit_stop_flush');
      } catch (error) {
        _logPcmSummary('explicit_stop_flush_error');
        _diag('event=pcm_flush_failed error_type=${error.runtimeType}');
      }
    }
    if (_activeListen) {
      _activeListen = false;
      _setStatus(SttStatus.stopped);
    }
  }

  @override
  void pause() {
    _activeListen = false;
    _setStatus(SttStatus.paused);
  }

  @override
  Future<void> resume() => start();

  @override
  void dispose() {
    _disposed = true;
    _activeListen = false;
    _stream?.free();
    _stream = null;
    _recognizer?.free();
    _recognizer = null;
    super.dispose();
  }
}
