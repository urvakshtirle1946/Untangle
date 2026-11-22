import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

class AndroidStartupSplash extends StatefulWidget {
  const AndroidStartupSplash({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<AndroidStartupSplash> createState() => _AndroidStartupSplashState();
}

class _AndroidStartupSplashState extends State<AndroidStartupSplash> {
  static const Color _splashBackground = Color(0xFF831FF0);
  static const Duration _stillFadeDuration = Duration(milliseconds: 220);
  // The Realme log showed about 2.4s of cold initialization latency.
  static const Duration _initializationTimeout = Duration(milliseconds: 10000);
  static const Duration _playbackSetupTimeout = Duration(milliseconds: 4000);
  static const Duration _stallTimeout = Duration(milliseconds: 8000);

  late final VideoPlayerController _controller;
  Timer? _stallTimer;
  bool _playerInitialized = false;
  bool _showMascotStill = true;
  bool _firstVideoFrameVisible = false;
  bool _disposeStarted = false;
  bool _finished = false;
  bool _fallbackRequested = false;
  bool _playingStarted = false;
  int _lastPositionBucket = -1;

  @override
  void initState() {
    super.initState();
    _log('player_initialize_started');
    unawaited(_hideSystemUi());
    _controller = VideoPlayerController.asset(
      'assets/splash/untangle-intro.mp4',
    );
    _controller.addListener(_onPlayerUpdate);
    unawaited(_initializeAndPlay());
  }

  Future<void> _initializeAndPlay() async {
    try {
      await _controller.initialize().timeout(_initializationTimeout);
      _log(
        'player_initialized duration_ms=${_controller.value.duration.inMilliseconds}',
      );
      await _controller.setVolume(0).timeout(_playbackSetupTimeout);
      await _controller.setLooping(false).timeout(_playbackSetupTimeout);

      if (!mounted) return;
      setState(() => _playerInitialized = true);
      // Attach the video texture underneath the mascot still before playback.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _finished) return;
      _log('playback_start_requested');
      await _controller.play().timeout(_playbackSetupTimeout);
      _playingStarted = true;
      _log('playback_started');
      _restartStallTimer();
    } catch (error, stackTrace) {
      _log('player_error exception=$error stack=$stackTrace');
      await _showFallbackAndFinish('player_error: $error');
      await _disposeController();
    }
  }

  void _onPlayerUpdate() {
    if (!mounted || _finished || _fallbackRequested) return;
    final VideoPlayerValue value = _controller.value;
    if (value.hasError) {
      _log(
        'player_error type=VideoPlayerError description=${value.errorDescription ?? 'unknown'}',
      );
      unawaited(_showFallbackAndFinish('player_error'));
      return;
    }
    if (_playingStarted &&
        !_firstVideoFrameVisible &&
        value.position >= const Duration(milliseconds: 80)) {
      _firstVideoFrameVisible = true;
      setState(() => _showMascotStill = false);
      // video_player has no rendered-frame callback; advanced playback
      // position is the first available signal that the attached texture has
      // started producing video frames.
      _log(
        'video_frame_ready_proxy position_ms=${value.position.inMilliseconds}',
      );
    }
    if (_playingStarted && value.isCompleted) {
      _stallTimer?.cancel();
      _log(
        'playback_completed position_ms=${value.position.inMilliseconds} duration_ms=${value.duration.inMilliseconds}',
      );
      _finish('playback_completed');
      return;
    }
    if (!_playingStarted || !value.isPlaying) return;

    final int bucket = value.position.inMilliseconds ~/ 250;
    if (bucket != _lastPositionBucket) {
      _lastPositionBucket = bucket;
      _log('playback_position_ms=${value.position.inMilliseconds}');
      _restartStallTimer();
    }
  }

  void _restartStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallTimeout, () {
      _log('playback_timeout phase=stalled');
      unawaited(_showFallbackAndFinish('playback_stalled'));
    });
  }

  Future<void> _showFallbackAndFinish(String reason) async {
    if (!mounted || _finished || _fallbackRequested) return;
    _fallbackRequested = true;
    setState(() {
      _playerInitialized = false;
      _showMascotStill = true;
    });
    _log('fallback_still reason=$reason');
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    unawaited(_disposeController());
    _finish(reason);
  }

  void _finish(String reason) {
    if (_finished) return;
    _finished = true;
    _stallTimer?.cancel();
    _log('splash_ready reason=$reason');
    widget.onFinished();
  }

  void _log(String message) {
    debugPrint('[startup-splash] $message');
  }

  Future<void> _disposeController() async {
    if (_disposeStarted) return;
    _disposeStarted = true;
    _stallTimer?.cancel();
    _controller.removeListener(_onPlayerUpdate);
    try {
      await _controller.dispose();
    } catch (_) {
      // Splash playback is optional; cleanup errors must not block startup.
    }
  }

  Future<void> _hideSystemUi() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      _log('system_ui_hide_error type=${error.runtimeType}');
    }
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error) {
      _log('system_ui_restore_error type=${error.runtimeType}');
    }
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    _controller.removeListener(_onPlayerUpdate);
    unawaited(_disposeController());
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _splashBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_playerInitialized && _controller.value.isInitialized)
            ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              ),
            ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showMascotStill ? 1 : 0,
              duration: _stillFadeDuration,
              child: const ColoredBox(
                color: _splashBackground,
                child: Center(
                  child: Image(
                    image: AssetImage(
                      'assets/splash/untangle-mascot-still.png',
                    ),
                    width: 288,
                    height: 288,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
