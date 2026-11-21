import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../player/widgets/player_screen_layout.dart';
import '../../player/services/note_audio_player_handler.dart';

abstract class NoteAudioPlaybackController {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<String> get errorStream;
  String? get initialErrorMessage;
  bool get isPlaying;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

/// Phase 1 controller: intentionally reports unavailable and never simulates
/// progress or playback. A real player can replace this in the audio phase.
class UnavailableNoteAudioPlaybackController
    implements NoteAudioPlaybackController {
  UnavailableNoteAudioPlaybackController(Note note)
    : initialErrorMessage = note.audioRecordingFailed
          ? 'Audio recording failed.'
          : note.hasAudio
          ? 'Audio playback is not available.'
          : 'No audio recorded for this note yet.';

  @override
  final String initialErrorMessage;

  @override
  bool get isPlaying => false;

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get durationStream => const Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<String> get errorStream => const Stream<String>.empty();

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

class PlayerHandlerNoteAudioPlaybackController
    implements NoteAudioPlaybackController {
  PlayerHandlerNoteAudioPlaybackController({
    required this.note,
    required this.handler,
  }) {
    _playbackSubscription = handler.playbackState.listen((state) {
      if (state.processingState == AudioProcessingState.error) {
        _errors.add(state.errorMessage ?? 'Audio playback failed.');
      }
    });
  }

  final Note note;
  final NoteAudioPlayerHandler handler;
  final StreamController<String> _errors = StreamController<String>.broadcast();
  late final StreamSubscription<PlaybackState> _playbackSubscription;
  bool _loaded = false;
  bool _disposed = false;

  @override
  String? get initialErrorMessage => note.hasAudio
      ? null
      : (note.audioRecordingFailed
            ? 'Audio recording failed.'
            : 'No audio recorded for this note yet.');

  @override
  bool get isPlaying => handler.isPlaying;

  @override
  Stream<Duration> get positionStream => handler.positionStream;

  @override
  Stream<Duration> get durationStream => handler.durationStream
      .where((Duration? duration) => duration != null)
      .cast<Duration>();

  @override
  Stream<bool> get playingStream => handler.playbackState
      .map((PlaybackState state) => state.playing)
      .distinct();

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> play() async {
    if (_disposed || !note.hasAudio) return;
    try {
      if (!_loaded) {
        await handler.loadNoteAudio(
          id: note.id,
          title: note.title,
          audioUrl: note.audioUrl ?? '',
          localAudioPaths: note.localAudioPaths,
          duration: note.duration,
        );
        _loaded = true;
      }
      await handler.play();
    } catch (error) {
      _loaded = false;
      _errors.add(error.toString());
    }
  }

  @override
  Future<void> pause() async {
    try {
      await handler.pause();
    } catch (error) {
      _errors.add(error.toString());
    }
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await handler.seek(position);
    } catch (error) {
      _errors.add(error.toString());
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _playbackSubscription.cancel();
    await _errors.close();
  }
}

class NoteAudioPage extends StatefulWidget {
  const NoteAudioPage({
    super.key,
    required this.note,
    this.controller,
  });

  final Note note;
  final NoteAudioPlaybackController? controller;

  @override
  State<NoteAudioPage> createState() => _NoteAudioPageState();
}

class _NoteAudioPageState extends State<NoteAudioPage>
    with WidgetsBindingObserver {
  late final NoteAudioPlaybackController _controller;
  late String? _errorMessage;
  late Duration _duration;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller =
        widget.controller ??
        (locator.isRegistered<PlayerHandler>()
            ? PlayerHandlerNoteAudioPlaybackController(
                note: widget.note,
                handler: locator<PlayerHandler>(),
              )
            : UnavailableNoteAudioPlaybackController(widget.note));
    _errorMessage = _controller.initialErrorMessage;
    _duration = widget.note.duration ?? Duration.zero;
    _isPlaying = _controller.isPlaying;
    _subscriptions.add(
      _controller.positionStream.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
    );
    _subscriptions.add(
      _controller.durationStream.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      }),
    );
    _subscriptions.add(
      _controller.playingStream.listen((isPlaying) {
        if (mounted) setState(() => _isPlaying = isPlaying);
      }),
    );
    _subscriptions.add(
      _controller.errorStream.listen((message) {
        if (mounted) {
          setState(() {
            _errorMessage = message;
            _isPlaying = false;
          });
        }
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_controller.pause());
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final StreamSubscription<dynamic> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_stopAndDisposeController());
    super.dispose();
  }

  Future<void> _stopAndDisposeController() async {
    await _controller.pause();
    await _controller.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_errorMessage != null) return;
    if (_isPlaying) {
      await _controller.pause();
      if (mounted) setState(() => _isPlaying = false);
    } else {
      await _controller.play();
      if (mounted) setState(() => _isPlaying = _controller.isPlaying);
    }
  }

  Future<void> _seekTo(Duration position) async {
    if (_errorMessage != null) return;
    final int maxMs = _duration.inMilliseconds;
    final Duration target = Duration(
      milliseconds: position.inMilliseconds.clamp(0, maxMs).toInt(),
    );
    await _controller.seek(target);
    if (mounted) setState(() => _position = target);
  }

  Widget _transcriptArea(BuildContext context) {
    final ColorScheme colors = widget.note.scheme(context);
    final TextStyle transcriptStyle =
        Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: colors.onSurface,
          fontSize: 22,
          height: 1.45,
          fontWeight: FontWeight.w500,
        ) ??
        TextStyle(
          color: colors.onSurface,
          fontSize: 22,
          height: 1.45,
          fontWeight: FontWeight.w500,
        );

    final List<Map<String, dynamic>>? messages =
        widget.note.conversationMessages;
    if (messages != null) {
      final List<_TranscriptTurn> turns = messages
          .map((message) {
            final String speaker =
                message['speaker']?.toString().toLowerCase() ?? '';
            return _TranscriptTurn(
              speaker: speaker == 'ai' || speaker == 'assistant' ? 'AI' : 'You',
              text: message['text'] as String? ?? '',
            );
          })
          .where((turn) => turn.text.trim().isNotEmpty)
          .toList(growable: false);

      if (turns.isEmpty) return _emptyTranscript(colors);

      return ListView.separated(
        padding: const EdgeInsets.only(right: 20, bottom: 16),
        itemCount: turns.length,
        separatorBuilder: (context, index) => const SizedBox(height: 24),
        itemBuilder: (context, index) {
          final _TranscriptTurn turn = turns[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  turn.speaker,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SelectableText(turn.text, style: transcriptStyle),
            ],
          );
        },
      );
    }

    final String? transcript = widget.note.transcript;
    if (transcript == null || transcript.trim().isEmpty) {
      return _emptyTranscript(colors);
    }

    return ListView(
      padding: const EdgeInsets.only(right: 20, bottom: 16),
      children: [SelectableText(transcript, style: transcriptStyle)],
    );
  }

  Widget _emptyTranscript(ColorScheme colors) => Center(
    child: Text(
      'No transcript available',
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
        color: colors.onSurfaceVariant,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bool canPlay = _errorMessage == null;
    final Duration remaining = _duration - _position;
    final String remainingLabel = remaining > Duration.zero
        ? '-${remaining.remainingLabel}'
        : _duration.remainingLabel;
    final double progress = _duration.inMilliseconds == 0
        ? 0
        : _position.inMilliseconds / _duration.inMilliseconds;

    return PlayerScreenLayout(
      title: '',
      titleArea: _transcriptArea(context),
      scheme: widget.note.scheme(context),
      remainingLabel: remainingLabel,
      progress: progress,
      playing: _isPlaying,
      loading: false,
      fav: false,
      controlsEnabled: canPlay,
      onPlayPause: _togglePlayback,
      onRewind: () => _seekTo(_position - const Duration(seconds: 10)),
      onFastForward: () => _seekTo(_position + const Duration(seconds: 10)),
      onFav: () => ComingSoon.show(context),
      statusMessage: _errorMessage,
    );
  }
}

class _TranscriptTurn {
  const _TranscriptTurn({required this.speaker, required this.text});

  final String speaker;
  final String text;
}
