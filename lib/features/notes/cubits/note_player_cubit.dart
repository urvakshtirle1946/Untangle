import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class NotePlayback {
  const NotePlayback({
    this.noteId,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  final String? noteId;
  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;

  double get progress {
    if (duration.inMilliseconds <= 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  Duration get timeLeft {
    if (duration > position) {
      return duration - position;
    }
    return Duration.zero;
  }
}

class NotePlayerCubit extends Cubit<NotePlayback> {
  NotePlayerCubit({PlayerHandler? handler})
    : _handler =
          handler ??
          (locator.isRegistered<PlayerHandler>()
              ? locator<PlayerHandler>()
              : null),
      super(const NotePlayback()) {
    _initSubscriptions();
  }

  final PlayerHandler? _handler;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;

  void _initSubscriptions() {
    if (_handler != null) {
      try {
        _positionSubscription = _handler.positionStream.listen((pos) {
          if (state.noteId != null) {
            emit(
              NotePlayback(
                noteId: state.noteId,
                playing: state.playing,
                loading: state.loading,
                position: pos,
                duration: _handler.duration ?? state.duration,
              ),
            );
          }
        });
      } catch (_) {}

      try {
        _playbackStateSubscription = _handler.playbackState.listen((ps) {
          if (state.noteId != null) {
            final bool isCompleted =
                ps.processingState == AudioProcessingState.completed;
            final bool isPlaying = ps.playing && !isCompleted;
            final bool isLoading =
                ps.processingState == AudioProcessingState.loading ||
                ps.processingState == AudioProcessingState.buffering;

            emit(
              NotePlayback(
                noteId: state.noteId,
                playing: isPlaying,
                loading: isLoading,
                position: _handler.position,
                duration: _handler.duration ?? state.duration,
              ),
            );
          }
        });
      } catch (_) {}
    }
  }

  Future<void> toggle(Note note) async {
    if (!note.hasAudio) return;

    if (state.noteId != note.id) {
      final Duration noteDur = note.duration ?? Duration.zero;
      emit(
        NotePlayback(
          noteId: note.id,
          playing: true,
          loading: true,
          position: Duration.zero,
          duration: noteDur,
        ),
      );

      if (_handler == null) {
        emit(const NotePlayback());
        return;
      }
      try {
        await _handler.loadNoteAudio(
          id: note.id,
          title: note.title,
          audioUrl: note.audioUrl ?? '',
          localAudioPaths: note.localAudioPaths,
          duration: note.duration,
        );
        await _handler.play();
      } catch (_) {
        emit(const NotePlayback());
      }
    } else {
      if (state.playing) {
        if (_handler != null) await _handler.pause();
        emit(
          NotePlayback(
            noteId: state.noteId,
            playing: false,
            loading: false,
            position: state.position,
            duration: state.duration,
          ),
        );
      } else {
        if (_handler != null) await _handler.play();
        emit(
          NotePlayback(
            noteId: state.noteId,
            playing: true,
            loading: false,
            position: state.position,
            duration: state.duration,
          ),
        );
      }
    }
  }

  Future<void> stop() async {
    if (_handler != null) {
      await _handler.stop();
    }
    emit(const NotePlayback());
  }

  @override
  Future<void> close() {
    _positionSubscription?.cancel();
    _playbackStateSubscription?.cancel();
    return super.close();
  }
}
