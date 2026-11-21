import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';

class VoiceAudioSegment {
  const VoiceAudioSegment({
    required this.path,
    required this.duration,
    required this.fileSizeBytes,
  });

  final String path;
  final Duration duration;
  final int fileSizeBytes;
}

abstract interface class VoiceNoteAudioCapture {
  Future<void> start();
  Future<VoiceAudioSegment> stop();
  Future<void> dispose();
}

/// A streaming capture whose raw PCM can be consumed by an on-device
/// recognizer while those exact bytes are written to the local audio file.
abstract interface class PcmVoiceNoteAudioCapture
    implements VoiceNoteAudioCapture {
  set onPcmChunk(void Function(Uint8List pcm16LittleEndian)? callback);
}

/// Voice-note capture writes mono 16 kHz PCM from one recorder stream to a WAV
/// file and forwards the same samples to the speech recognizer.
class ConversationPcmVoiceNoteAudioCapture implements PcmVoiceNoteAudioCapture {
  ConversationPcmVoiceNoteAudioCapture({
    this._onPcmChunk,
    this.filePrefix = 'conversation',
    AudioRecorder? recorder,
  }) : _recorder = recorder ?? AudioRecorder();

  final String filePrefix;

  static const int sampleRate = 16000;
  static const int numChannels = 1;
  static const int _bytesPerSample = 2;
  static const RecordConfig _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: sampleRate,
    numChannels: numChannels,
    audioInterruption: AudioInterruptionMode.none,
    androidConfig: AndroidRecordConfig(manageBluetooth: false),
  );

  final AudioRecorder _recorder;
  void Function(Uint8List pcm16LittleEndian)? _onPcmChunk;
  RandomAccessFile? _file;
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _streamDone;
  Future<void> _writeQueue = Future<void>.value();
  String? _path;
  int _pcmBytes = 0;
  int _pcmChunks = 0;
  int _pcmSamples = 0;
  int _pcmNonzeroSamples = 0;
  int _pcmPeakAbs = 0;
  double _pcmSumSquares = 0;
  bool _reportedFirstChunk = false;
  bool _stopRequested = false;
  Object? _streamError;
  bool _started = false;

  void _diag(String event) {
    if (kDebugMode) debugPrint('[voice-note-audio] $event');
  }

  @override
  set onPcmChunk(void Function(Uint8List pcm16LittleEndian)? callback) =>
      _onPcmChunk = callback;

  @override
  Future<void> start() async {
    if (_started) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission was denied.');
    }
    final Directory support = await getApplicationSupportDirectory();
    final Directory recordings = Directory(
      '${support.path}${Platform.pathSeparator}voice_notes',
    );
    await recordings.create(recursive: true);
    final String path =
        '${recordings.path}${Platform.pathSeparator}'
        '$filePrefix-${DateTime.now().microsecondsSinceEpoch}.wav';
    final RandomAccessFile file = await File(path).open(mode: FileMode.write);
    _path = path;
    _file = file;
    _pcmBytes = 0;
    _pcmChunks = 0;
    _pcmSamples = 0;
    _pcmNonzeroSamples = 0;
    _pcmPeakAbs = 0;
    _pcmSumSquares = 0;
    _reportedFirstChunk = false;
    _stopRequested = false;
    _streamError = null;
    try {
      await file.writeFrom(List<int>.filled(44, 0));
      final Stream<Uint8List> pcm = await _recorder.startStream(_config);
      _started = true;
      _streamDone = Completer<void>();
      _subscription = pcm.listen(
        _onPcmData,
        onError: (Object error, StackTrace stackTrace) {
          _streamError = error;
          _diag(
            'event=shared_pcm_stream_error error_type=${error.runtimeType}',
          );
          final Completer<void>? done = _streamDone;
          if (done != null && !done.isCompleted) done.complete();
        },
        onDone: () {
          _diag(
            'event=shared_pcm_stream_done reason=${_stopRequested ? 'recorder_stop_requested' : 'unexpected_stream_completion'}',
          );
          final Completer<void>? done = _streamDone;
          if (done != null && !done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
    } catch (_) {
      await _deletePartial();
      await _recorder.dispose();
      rethrow;
    }
  }

  void _onPcmData(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final Uint8List chunk = Uint8List.fromList(pcm);
    _pcmChunks++;
    _pcmBytes += chunk.length;
    final int sampleCount = chunk.length ~/ _bytesPerSample;
    final ByteData samples = ByteData.sublistView(chunk);
    for (var index = 0; index < sampleCount; index++) {
      final int sample = samples.getInt16(
        index * _bytesPerSample,
        Endian.little,
      );
      final int absolute = sample.abs();
      if (absolute > _pcmPeakAbs) _pcmPeakAbs = absolute;
      if (sample != 0) _pcmNonzeroSamples++;
      _pcmSumSquares += sample * sample;
    }
    _pcmSamples += sampleCount;
    if (!_reportedFirstChunk) {
      _reportedFirstChunk = true;
      _diag(
        'event=shared_pcm_first_chunk bytes=${chunk.length} samples=$sampleCount',
      );
    }
    _writeQueue = _writeQueue.then((_) async {
      await _file?.writeFrom(chunk);
    });
    try {
      _onPcmChunk?.call(chunk);
    } catch (error) {
      _streamError ??= error;
    }
  }

  @override
  Future<VoiceAudioSegment> stop() async {
    if (!_started || _path == null || _file == null) {
      throw StateError('Conversation audio capture was not started.');
    }
    final String path = _path!;
    try {
      _stopRequested = true;
      await _recorder.stop();
      final Completer<void>? done = _streamDone;
      if (done != null && !done.isCompleted) {
        await done.future.timeout(const Duration(seconds: 3));
      }
      await _subscription?.cancel();
      _subscription = null;
      await _writeQueue;
      final double rms = _pcmSamples == 0
          ? 0
          : math.sqrt(_pcmSumSquares / _pcmSamples) / 32768;
      _diag(
        'event=shared_pcm_capture_summary chunks=$_pcmChunks bytes=$_pcmBytes samples=$_pcmSamples nonzero_samples=$_pcmNonzeroSamples peak_abs=$_pcmPeakAbs rms_normalized=${rms.toStringAsFixed(6)}',
      );
      if (_streamError != null) {
        throw StateError(
          'PCM capture stream failed (${_streamError.runtimeType}).',
        );
      }
      if (_pcmBytes <= 0 || _pcmBytes % _bytesPerSample != 0) {
        throw StateError('PCM capture did not produce valid audio samples.');
      }
      final RandomAccessFile file = _file!;
      await file.setPosition(0);
      await file.writeFrom(_waveHeader(_pcmBytes));
      await file.flush();
      await file.close();
      _file = null;
      _started = false;

      final File audioFile = File(path);
      final int size = await audioFile.length();
      final Duration measured = Duration(
        microseconds:
            (_pcmBytes * Duration.microsecondsPerSecond) ~/
            (sampleRate * numChannels * _bytesPerSample),
      );
      final AudioPlayer probe = AudioPlayer();
      try {
        final Duration? parsed = await probe.setFilePath(path);
        if (parsed == null || parsed <= Duration.zero) {
          throw StateError('The finalized WAV has no readable duration.');
        }
      } finally {
        await probe.dispose();
      }
      return VoiceAudioSegment(
        path: path,
        duration: measured,
        fileSizeBytes: size,
      );
    } catch (_) {
      await _deletePartial();
      rethrow;
    } finally {
      _started = false;
      try {
        await _recorder.dispose();
      } catch (_) {}
    }
  }

  Uint8List _waveHeader(int dataLength) {
    final ByteData header = ByteData(44);
    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(
      28,
      sampleRate * numChannels * _bytesPerSample,
      Endian.little,
    );
    header.setUint16(32, numChannels * _bytesPerSample, Endian.little);
    header.setUint16(34, _bytesPerSample * 8, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);
    return header.buffer.asUint8List();
  }

  Future<void> _deletePartial() async {
    try {
      await _file?.close();
    } catch (_) {}
    _file = null;
    final String? path = _path;
    _path = null;
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_started) {
      try {
        await stop();
      } catch (_) {
        await _deletePartial();
      }
    }
  }
}

class FileVoiceNoteAudioCapture implements VoiceNoteAudioCapture {
  AudioRecorder? _recorder;
  String? _path;
  bool _started = false;

  static const RecordConfig _config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 128000,
    sampleRate: 44100,
    audioInterruption: AudioInterruptionMode.none,
    androidConfig: AndroidRecordConfig(manageBluetooth: false),
  );

  @override
  Future<void> start() async {
    if (_started) return;
    final AudioRecorder recorder = AudioRecorder();
    _recorder = recorder;
    try {
      if (!await recorder.hasPermission()) {
        throw StateError('Microphone permission was denied.');
      }
      final Directory support = await getApplicationSupportDirectory();
      final Directory recordings = Directory(
        '${support.path}${Platform.pathSeparator}voice_notes',
      );
      await recordings.create(recursive: true);
      final String path =
          '${recordings.path}${Platform.pathSeparator}'
          'voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
      _path = path;
      await recorder.start(_config, path: path);
      _started = true;
    } catch (_) {
      await _disposeRecorder();
      await _deletePartialFile();
      rethrow;
    }
  }

  @override
  Future<VoiceAudioSegment> stop() async {
    if (!_started || _recorder == null || _path == null) {
      throw StateError('Audio capture was not started.');
    }
    final AudioRecorder recorder = _recorder!;
    final String expectedPath = _path!;
    String path = expectedPath;
    try {
      path = await recorder.stop() ?? expectedPath;
      _started = false;
      final File file = File(path);
      if (!await file.exists()) {
        throw StateError('The recorder did not create an audio file.');
      }
      final int size = await file.length();
      if (size <= 0) throw StateError('The audio file is empty.');
      final AudioPlayer probe = AudioPlayer();
      Duration? duration;
      try {
        duration = await probe.setFilePath(path);
      } finally {
        await probe.dispose();
      }
      if (duration == null || duration <= Duration.zero) {
        throw StateError('The finalized audio has no readable duration.');
      }
      return VoiceAudioSegment(
        path: path,
        duration: duration,
        fileSizeBytes: size,
      );
    } catch (_) {
      try {
        final File partialFile = File(path);
        if (await partialFile.exists()) await partialFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      _started = false;
      await _disposeRecorder();
    }
  }

  @override
  Future<void> dispose() async {
    if (_started) {
      try {
        await stop();
      } catch (_) {
        await _disposeRecorder();
      }
    } else {
      await _disposeRecorder();
    }
  }

  Future<void> _disposeRecorder() async {
    final AudioRecorder? recorder = _recorder;
    _recorder = null;
    if (recorder != null) await recorder.dispose();
  }

  Future<void> _deletePartialFile() async {
    final String? path = _path;
    _path = null;
    if (path == null) return;
    try {
      final File partialFile = File(path);
      if (await partialFile.exists()) await partialFile.delete();
    } catch (_) {}
  }
}

class LocalNoteAudioReference {
  const LocalNoteAudioReference({
    required this.paths,
    required this.duration,
    required this.fileSizeBytes,
    this.recordingFailed = false,
  });

  final List<String> paths;
  final Duration duration;
  final int fileSizeBytes;
  final bool recordingFailed;
}

/// Persists only device-local audio references. Cloud audio_url remains intact.
class LocalNoteAudioStore {
  static const String _keyPrefix = 'untangle.local_note_audio.';

  Future<void> save(String noteId, LocalNoteAudioReference reference) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      '$_keyPrefix$noteId',
      jsonEncode(<String, Object>{
        'paths': reference.paths,
        'duration_ms': reference.duration.inMilliseconds,
        'file_size_bytes': reference.fileSizeBytes,
        'recording_failed': reference.recordingFailed,
      }),
    );
  }

  Future<LocalNoteAudioReference?> read(String noteId) async {
    try {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final String? encoded = preferences.getString('$_keyPrefix$noteId');
      if (encoded == null) return null;
      final Map<String, dynamic> data =
          jsonDecode(encoded) as Map<String, dynamic>;
      final List<String> paths = (data['paths'] as List<dynamic>)
          .cast<String>();
      final bool recordingFailed = data['recording_failed'] as bool? ?? false;
      if (paths.isEmpty && !recordingFailed) return null;
      for (final String path in paths) {
        if (!await File(path).exists()) return null;
      }
      return LocalNoteAudioReference(
        paths: paths,
        duration: Duration(milliseconds: data['duration_ms'] as int? ?? 0),
        fileSizeBytes: data['file_size_bytes'] as int? ?? 0,
        recordingFailed: recordingFailed,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<Note>> attachToNotes(Iterable<Note> notes) async {
    final List<Note> result = <Note>[];
    try {
      for (final Note note in notes) {
        final LocalNoteAudioReference? reference = await read(note.id);
        result.add(
          reference == null
              ? note
              : note.copyWith(
                  localAudioPaths: reference.paths,
                  localAudioFileSizeBytes: reference.fileSizeBytes,
                  duration: reference.paths.isEmpty
                      ? note.duration
                      : reference.duration,
                  audioRecordingFailed: reference.recordingFailed,
                ),
        );
      }
      return result;
    } catch (_) {
      return List<Note>.from(notes);
    }
  }

  Future<void> remove(String noteId) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_keyPrefix$noteId');
  }
}
