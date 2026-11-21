import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:bunpod/bunpod.dart';
import 'package:just_audio/just_audio.dart';

import 'note_audio_player_handler.dart';

class PlayerHandler extends BaseAudioHandler
    with SeekHandler
    implements NoteAudioPlayerHandler {
  PlayerHandler() {
    _player.playbackEventStream.listen((_) => _broadcast());
    _player.playingStream.listen((_) => _broadcast());
    _player.durationStream.listen(_updateDuration);
  }

  final AudioPlayer _player = AudioPlayer();

  static Future<PlayerHandler> init() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    return AudioService.init(
      builder: PlayerHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'app.bunpod.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
        rewindInterval: Duration(seconds: 15),
        fastForwardInterval: Duration(seconds: 30),
      ),
    );
  }

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  bool get isPlaying => _player.playing;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  Stream<PositionDiscontinuity> get seeks => _player.positionDiscontinuityStream
      .where((event) => event.reason == PositionDiscontinuityReason.seek);

  Future<void> load(Episode episode) async {
    mediaItem.add(
      MediaItem(
        id: '${episode.id}',
        title: episode.title ?? '',
        artist: episode.channel?.title,
        artUri: Uri.tryParse(episode.cover),
        duration: episode.total > Duration.zero ? episode.total : null,
      ),
    );

    await _player.setAudioSource(
      AudioSource.uri(Uri.parse(episode.audioUrl ?? '')),
      initialPosition: episode.completed == true ? null : episode.listened,
    );
  }

  @override
  Future<void> loadNoteAudio({
    required String id,
    required String title,
    required String audioUrl,
    List<String> localAudioPaths = const <String>[],
    Duration? duration,
  }) async {
    mediaItem.add(
      MediaItem(
        id: 'note_$id',
        title: title,
        artist: 'Note Audio',
        duration: duration,
      ),
    );

    if (localAudioPaths.isNotEmpty) {
      final List<AudioSource> sources = localAudioPaths
          .map((String path) => AudioSource.file(path))
          .toList(growable: false);
      await _player.setAudioSources(sources);
    } else {
      final Uri? uri = Uri.tryParse(audioUrl);
      if (uri != null) await _player.setAudioSource(AudioSource.uri(uri));
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  void _updateDuration(Duration? duration) {
    final MediaItem? item = mediaItem.value;

    if (item != null && duration != null) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  void _broadcast() {
    final bool playing = _player.playing;

    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ),
    );
  }
}
