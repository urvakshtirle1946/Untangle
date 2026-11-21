import 'package:audio_service/audio_service.dart';

/// Player operations the note-audio controller needs. Keeping this boundary
/// small lets widget tests use a fake without constructing AudioPlayer.
abstract interface class NoteAudioPlayerHandler {
  Stream<PlaybackState> get playbackState;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  bool get isPlaying;

  Future<void> loadNoteAudio({
    required String id,
    required String title,
    required String audioUrl,
    List<String> localAudioPaths = const <String>[],
    Duration? duration,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
}
