import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bunpod/bunpod.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../services/voice_note_audio.dart';
import '../stt/sherpa_streaming_stt_adapter.dart';

/// Full-screen note creation screen with Voice and Type tabs.
///
/// **Record Tab**:
/// - Multiline speech-to-text transcript box with in-place partial recognition
///   and deduplicated finalized utterances.
/// - Allows manual edits while paused; edits are preserved when resuming.
/// - Compact Start/Pause recording control with honest disconnected status.
///
/// **Conversation Tab**:
/// - Scrollable WhatsApp-style conversation bubbles (user on right, AI on left).
/// - Live user partial updates and finalized utterances.
/// - Display AI response text matching voice playback.
/// - Compact Start/Stop conversation control.
class CreateNoteScreen extends StatefulWidget {
  const CreateNoteScreen({
    super.key,
    this.transcriptState,
    this.conversationSession,
    this.sttAdapter,
    this.notesRepository,
    this.latestNoteCubit,
    this.userId,
    this.conversationAiClient,
    this.voiceAudioCaptureFactory,
    this.localNoteAudioStore,
  });

  /// Injected transcript state (defaults to disconnected if omitted).
  final TranscriptState? transcriptState;

  /// Injected conversation session (defaults to disconnected if omitted).
  final ConversationSession? conversationSession;
  final SttAdapter? sttAdapter;
  final NotesRepository? notesRepository;
  final LatestNoteCubit? latestNoteCubit;
  final String? userId;
  final ConversationAiClient? conversationAiClient;
  final VoiceNoteAudioCapture Function()? voiceAudioCaptureFactory;
  final LocalNoteAudioStore? localNoteAudioStore;

  static Future<Note?> open(
    BuildContext context, {
    LatestNoteCubit? latestNoteCubit,
  }) async {
    final route = MaterialPageRoute<Note>(
      builder: (_) => CreateNoteScreen(latestNoteCubit: latestNoteCubit),
      fullscreenDialog: true,
    );
    final Note? note = await Navigator.of(context).push(route);
    await route.completed;
    debugPrint(
      '[note-category] event=composer_route_popped saved=${note != null}',
    );
    return note;
  }

  @override
  State<CreateNoteScreen> createState() => _CreateNoteScreenState();
}

enum _Tab { voice, type }

enum _VoiceMode { record, conversation }

typedef ConversationDiagnosticCallback = void Function(
  String event, {
  int? listenGeneration,
  String? requestId,
  String? details,
});

class _CreateNoteScreenState extends State<CreateNoteScreen>
    with WidgetsBindingObserver {
  _Tab _tab = _Tab.voice;
  _VoiceMode _voiceMode = _VoiceMode.record;

  // Typed draft survives tab switches
  final TextEditingController _draftController = TextEditingController();
  final FocusNode _draftFocus = FocusNode();

  // State instances for Record and Conversation tabs
  late final TranscriptState _transcriptState;
  late final ConversationSession _conversationSession;
  final ValueNotifier<bool> _conversationVoiceSession = ValueNotifier<bool>(
    false,
  );
  int _conversationGeneration = 0;
  late final ConversationAiClient? _conversationAiClient;
  late final bool _ownsTranscriptState;
  late final bool _ownsConversationSession;
  late final SttAdapter _recordSttAdapter;
  late final SttAdapter _conversationSttAdapter;
  late final bool _ownsSttAdapters;
  late final LatestNoteCubit _latestNoteCubit;
  late final bool _ownsLatestNoteCubit;
  late final LocalNoteAudioStore _localNoteAudioStore;
  bool _transcriptRevealed = false;
  bool _finishInProgress = false;
  bool _closeInProgress = false;
  bool _voiceModeChangeInProgress = false;
  bool _allowPop = false;
  String? _pendingSaveId;
  bool _aiRequestInFlight = false;
  VoiceNoteAudioCapture? _activeVoiceAudioCapture;
  final List<VoiceAudioSegment> _voiceAudioSegments = <VoiceAudioSegment>[];
  Future<void>? _voiceAudioStopInFlight;
  bool _voiceAudioCaptureFailed = false;
  bool _voiceAudioCaptureAttempted = false;
  final Stopwatch _conversationDiagClock = Stopwatch();
  String _conversationDiagSessionId = 'none';
  int _conversationDiagListenGeneration = 0;
  String? _conversationDiagRequestId;
  int? _conversationDiagRequestListenGeneration;
  Stopwatch? _conversationDiagEndToFinalTimer;
  Stopwatch? _conversationDiagReplyToDisplayTimer;
  Stopwatch? _conversationDiagDisplayToRestartTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _localNoteAudioStore = widget.localNoteAudioStore ?? LocalNoteAudioStore();

    if (widget.transcriptState != null) {
      _transcriptState = widget.transcriptState!;
      _ownsTranscriptState = false;
    } else {
      _transcriptState = TranscriptState(isConnected: true);
      _ownsTranscriptState = true;
    }
    // This screen always wires a recognizer adapter, including injected state.
    _transcriptState.setConnected(true);
    _recordSttAdapter = widget.sttAdapter ?? SherpaStreamingSttAdapter();
    _conversationSttAdapter = widget.sttAdapter ?? SherpaStreamingSttAdapter();
    _ownsSttAdapters = widget.sttAdapter == null;
    _recordSttAdapter.setDiagnosticLogger(
      _onSttDiagnostic,
      listenGenerationProvider: () => _conversationDiagListenGeneration,
    );

    _conversationAiClient =
        widget.conversationAiClient ??
        (SupabaseConfig.isConfigured ? _tryCreateConversationAiClient() : null);

    if (widget.conversationSession != null) {
      _conversationSession = widget.conversationSession!;
      _ownsConversationSession = false;
    } else {
      _conversationSession = ConversationSession(
        isConnected: _conversationAiClient != null && _hasSignedInSession(),
      );
      _ownsConversationSession = true;
    }
    _conversationVoiceSession.addListener(_onConversationVoiceSessionChanged);

    if (widget.latestNoteCubit != null) {
      _latestNoteCubit = widget.latestNoteCubit!;
      _ownsLatestNoteCubit = false;
    } else if (widget.notesRepository != null) {
      _latestNoteCubit = LatestNoteCubit(repository: widget.notesRepository);
      _ownsLatestNoteCubit = true;
    } else if (locator.isRegistered<LatestNoteCubit>()) {
      _latestNoteCubit = locator<LatestNoteCubit>();
      _ownsLatestNoteCubit = false;
    } else {
      _latestNoteCubit = LatestNoteCubit();
      _ownsLatestNoteCubit = true;
    }
  }

  SttAdapter get _activeSttAdapter => _voiceMode == _VoiceMode.conversation
      ? _conversationSttAdapter
      : _recordSttAdapter;

  ConversationAiClient? _tryCreateConversationAiClient() {
    try {
      return SupabaseConversationAiClient();
    } catch (_) {
      return null;
    }
  }

  bool _hasSignedInSession() {
    try {
      return sb.Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      return false;
    }
  }

  String _newConversationDiagnosticId() {
    final math.Random random = math.Random.secure();
    return 'conv-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${random.nextInt(1 << 32).toRadixString(16)}';
  }

  void _diag(
    String event, {
    int? listenGeneration,
    String? requestId,
    String? details,
  }) {
    if (!kDebugMode) return;
    final String resolvedRequestId =
        requestId ?? _conversationDiagRequestId ?? 'none';
    String detailFields = details == null ? '' : ' $details';
    if (event.startsWith('event=restart_acknowledged') &&
        _conversationDiagDisplayToRestartTimer != null) {
      detailFields +=
          ' display_to_restart_ms=${_conversationDiagDisplayToRestartTimer!.elapsedMilliseconds}';
      _conversationDiagDisplayToRestartTimer = null;
    }
    debugPrint(
      '[conv-diag] elapsed_ms=${_conversationDiagClock.elapsedMilliseconds} session_id=$_conversationDiagSessionId listen_generation=${listenGeneration ?? _conversationDiagRequestListenGeneration ?? _conversationDiagListenGeneration} sessionActive=${_conversationVoiceSession.value} requestPending=$_aiRequestInFlight request_id=$resolvedRequestId $event$detailFields',
    );
  }

  void _recordDiag(String event) {
    if (!kDebugMode) return;
    debugPrint('[voice-note-audio] $event');
  }

  String _redactRecordPostgrestField(String value, Note note) {
    String redacted = value;
    for (final String sensitive in <String?>[
      note.title,
      note.preview,
      note.transcript,
      note.userId,
    ].whereType<String>().where((String value) => value.isNotEmpty)) {
      redacted = redacted.replaceAll(sensitive, '[REDACTED]');
    }
    return redacted
        .replaceAll(
          RegExp(r'\bBearer\s+\S+', caseSensitive: false),
          'Bearer [REDACTED]',
        )
        .replaceAll(
          RegExp(r'\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
          '[REDACTED_TOKEN]',
        )
        .replaceAll(
          RegExp(r'\bsb_(?:publishable|secret)_[A-Za-z0-9_-]+\b'),
          '[REDACTED_KEY]',
        );
  }

  int _nextConversationListenGeneration() =>
      ++_conversationDiagListenGeneration;

  void _onSttDiagnostic(String event, {int? listenGeneration}) {
    if (_voiceMode != _VoiceMode.conversation) return;
    final int generation =
        listenGeneration ?? _conversationDiagListenGeneration;
    _diag(event, listenGeneration: generation);
    if (event.contains('event=plugin_status') &&
        (event.contains('raw_status=notListening') ||
            event.contains('raw_status=done'))) {
      _conversationDiagEndToFinalTimer ??= Stopwatch()..start();
    }
    if (event.contains('event=result_arrived isFinal=true') &&
        _conversationDiagEndToFinalTimer != null) {
      _diag(
        'event=end_status_to_final_result_checkpoint',
        listenGeneration: generation,
        details:
            'elapsed_since_last_end_status_ms=${_conversationDiagEndToFinalTimer!.elapsedMilliseconds} status_source_generation=unknown',
      );
      _conversationDiagEndToFinalTimer = null;
    }
    if (event.contains('raw_status=listening')) {
      _diag(
        'event=listening_acknowledged callback_scope=initialize_global',
        listenGeneration: generation,
      );
    }
  }

  Future<void> _sendConversationTurn(
    String userMessageId,
    String text, {
    int? listenGeneration,
    Stopwatch? finalToRequestTimer,
  }) async {
    final ConversationAiClient? client = _conversationAiClient;
    if (text.trim().isEmpty || !_conversationVoiceSession.value) return;
    if (_aiRequestInFlight) return;
    _aiRequestInFlight = true;
    if (mounted) setState(() {});
    final Stopwatch requestTimer = Stopwatch()..start();
    final String requestId = _newConversationDiagnosticId();
    final int requestListenGeneration =
        listenGeneration ?? _conversationDiagListenGeneration;
    final Stopwatch finalToRequestClock = finalToRequestTimer ?? Stopwatch();
    if (!finalToRequestClock.isRunning) finalToRequestClock.start();
    _conversationDiagRequestId = requestId;
    _conversationDiagRequestListenGeneration = requestListenGeneration;
    final int requestGeneration = _conversationGeneration;
    final List<ConversationMessage> previousMessages =
        _conversationSession.messages;
    final int userIndex = previousMessages.indexWhere(
      (message) => message.id == userMessageId,
    );
    final ConversationMessage? userMessage = userIndex < 0
        ? null
        : previousMessages[userIndex];
    if (userMessage == null || userMessage.isPartial) {
      _aiRequestInFlight = false;
      _diag(
        'event=request_pending_cleared reason=invalid_user_message',
        listenGeneration: requestListenGeneration,
        requestId: requestId,
      );
      if (mounted) setState(() {});
      return;
    }
    final String pendingAiMessageId = _conversationSession.ensurePendingAiReply(
      userMessage.id,
    );
    _conversationSession.setStatus(ConversationStatus.thinking);
    final List<ConversationMessage> requestHistory = previousMessages
        .take(userIndex + 1)
        .toList(growable: false);
    if (mounted) setState(() {});
    _diag(
      'event=request_sent user_message_id=${userMessage.id}',
      listenGeneration: requestListenGeneration,
      requestId: requestId,
      details:
          'final_transcript_to_request_sent_ms=${finalToRequestClock.elapsedMilliseconds}',
    );
    try {
      if (client == null) {
        throw const ConversationAiException(
          'The conversation service is unavailable. Check its Supabase setup.',
          code: 'client_unavailable',
        );
      }
      final String response;
      if (client is SupabaseConversationAiClient) {
        response = await client.replyWithRequestId(
          requestHistory,
          requestId: requestId,
          sessionId: _conversationDiagSessionId,
          listenGeneration: requestListenGeneration,
          onDiagnostic: (String event, int elapsedMilliseconds) {
            _diag(
              event,
              listenGeneration: requestListenGeneration,
              requestId: requestId,
              details: 'client_request_duration_ms=$elapsedMilliseconds',
            );
          },
        );
      } else {
        response = await client.reply(requestHistory);
      }
      _diag(
        'event=reply_received',
        listenGeneration: requestListenGeneration,
        requestId: requestId,
        details: 'request_duration_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (!mounted ||
          requestGeneration != _conversationGeneration ||
          !_conversationVoiceSession.value) {
        return;
      }
      _conversationDiagReplyToDisplayTimer = Stopwatch()..start();
      _conversationSession.resolveAiReply(pendingAiMessageId, response);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _conversationDiagReplyToDisplayTimer == null) return;
        final int displayedInMs =
            _conversationDiagReplyToDisplayTimer!.elapsedMilliseconds;
        _conversationDiagReplyToDisplayTimer = null;
        _diag(
          'event=reply_displayed',
          listenGeneration: requestListenGeneration,
          requestId: requestId,
          details: 'response_to_display_ms=$displayedInMs',
        );
        _conversationDiagDisplayToRestartTimer = Stopwatch()..start();
      });
    } on ConversationAiException catch (error) {
      _diag(
        'event=reply_failed code=${error.code} status=${error.statusCode ?? 'none'}',
        listenGeneration: requestListenGeneration,
        requestId: requestId,
        details: 'request_duration_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (mounted &&
          requestGeneration == _conversationGeneration &&
          _conversationVoiceSession.value) {
        _conversationSession.failAiReply(
          pendingAiMessageId,
          'Reply failed. Tap Retry.',
        );
        _conversationSession.setError(error.message);
      }
    } catch (error, stackTrace) {
      _diag(
        'event=reply_failed code=unexpected error_type=${error.runtimeType}',
        listenGeneration: requestListenGeneration,
        requestId: requestId,
        details: 'request_duration_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (kDebugMode) {
        debugPrintStack(
          stackTrace: stackTrace,
          label: '[conv-diag] unexpected AI reply processing error',
        );
      }
      if (mounted &&
          requestGeneration == _conversationGeneration &&
          _conversationVoiceSession.value) {
        _conversationSession.failAiReply(
          pendingAiMessageId,
          'Reply failed. Tap Retry.',
        );
        _conversationSession.setError(
          'The AI service failed unexpectedly. Please try again.',
        );
      }
    } finally {
      _aiRequestInFlight = false;
      _diag(
        'event=request_pending_cleared',
        listenGeneration: requestListenGeneration,
        requestId: requestId,
      );
      if (mounted) setState(() {});
    }
  }

  void _onConversationVoiceSessionChanged() {
    _conversationGeneration++;
    if (_conversationVoiceSession.value) {
      _conversationDiagSessionId = _newConversationDiagnosticId();
      _conversationDiagClock
        ..reset()
        ..start();
      _conversationDiagListenGeneration = 0;
      _conversationDiagRequestListenGeneration = null;
      _conversationDiagRequestId = null;
      _conversationDiagEndToFinalTimer = null;
      _conversationDiagReplyToDisplayTimer = null;
      _conversationDiagDisplayToRestartTimer = null;
      _diag('event=session_started');
    } else {
      _diag('event=session_stopped');
      _conversationSession.removePendingAiReplies();
    }
    if (mounted) {
      setState(() {
        _isVoiceActive = _voiceMode == _VoiceMode.conversation
            ? _conversationVoiceSession.value
            : _isVoiceActive;
      });
    }
  }

  Future<void> _retryConversationReply(String userMessageId) async {
    if (!_conversationVoiceSession.value) return;
    final List<ConversationMessage> messages = _conversationSession.messages;
    if (messages.isEmpty || _aiRequestInFlight) return;
    final ConversationMessage? failedReply = messages
        .where(
          (message) =>
              message.isError && message.replyToMessageId == userMessageId,
        )
        .firstOrNull;
    if (failedReply == null) {
      return;
    }
    final ConversationMessage? lastUser = messages
        .where((message) => message.id == userMessageId)
        .firstOrNull;
    if (lastUser == null || lastUser.speaker != ConversationSpeaker.user) {
      return;
    }
    await _sendConversationTurn(lastUser.id, lastUser.text);
  }

  Future<void> _stopAppPlaybackForCapture() async {
    if (locator.isRegistered<PlayerHandler>()) {
      await locator<PlayerHandler>().stop();
    }
  }

  Future<void> _startVoiceAudioCapture() async {
    final Future<void>? stopping = _voiceAudioStopInFlight;
    if (stopping != null) await stopping;
    if (_activeVoiceAudioCapture != null) return;
    final Future<void>? existingStart = _voiceAudioStartInFlight;
    if (existingStart != null) return existingStart;
    final Future<void> operation = _beginVoiceAudioCapture();
    _voiceAudioStartInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_voiceAudioStartInFlight, operation)) {
        _voiceAudioStartInFlight = null;
      }
    }
  }

  Future<void> _beginVoiceAudioCapture() async {
    _voiceAudioCaptureAttempted = true;
    final bool isConversation = _voiceMode == _VoiceMode.conversation;
    final SttAdapter adapter = isConversation
        ? _conversationSttAdapter
        : _recordSttAdapter;
    if (isConversation && adapter is! PcmInputSttAdapter) {
      _voiceAudioCaptureFailed = true;
      _showAudioCaptureFailure();
      return;
    }
    if (adapter is PcmInputSttAdapter) {
      final VoiceNoteAudioCapture capture =
          widget.voiceAudioCaptureFactory?.call() ??
          ConversationPcmVoiceNoteAudioCapture(
            filePrefix: isConversation ? 'conversation' : 'record',
          );
      if (capture is! PcmVoiceNoteAudioCapture) {
        _voiceAudioCaptureFailed = true;
        _showAudioCaptureFailure();
        return;
      }
      final PcmInputSttAdapter pcmAdapter = adapter as PcmInputSttAdapter;
      var recordFirstChunkLogged = false;
      capture.onPcmChunk = (Uint8List pcm) {
        if (!isConversation &&
            !recordFirstChunkLogged &&
            adapter.status == SttStatus.listening) {
          recordFirstChunkLogged = true;
          _recordDiag(
            'event=record_transcript_first_chunk bytes=${pcm.length}',
          );
        }
        pcmAdapter.addPcmChunk(
          pcm,
          sampleRate: ConversationPcmVoiceNoteAudioCapture.sampleRate,
        );
      };
      _activeVoiceAudioCapture = capture;
      try {
        await capture.start();
        _voiceAudioCaptureFailed = false;
        if (kDebugMode) {
          debugPrint(
            '[voice-note-audio] event=shared_pcm_capture_started mode=${isConversation ? 'conversation' : 'record'} sample_rate=16000 channels=1',
          );
        }
      } catch (error) {
        _activeVoiceAudioCapture = null;
        _voiceAudioCaptureFailed = true;
        try {
          await capture.dispose();
        } catch (_) {}
        debugPrint(
          '[voice-note-audio] event=shared_pcm_capture_start_failed mode=${isConversation ? 'conversation' : 'record'} error_type=${error.runtimeType}',
        );
        _showAudioCaptureFailure();
      }
      return;
    }

    final VoiceNoteAudioCapture capture =
        widget.voiceAudioCaptureFactory?.call() ?? FileVoiceNoteAudioCapture();
    _activeVoiceAudioCapture = capture;
    try {
      await capture.start();
      _voiceAudioCaptureFailed = false;
      if (kDebugMode) {
        debugPrint('[voice-note-audio] event=recording_started mode=record');
      }
    } catch (error) {
      _activeVoiceAudioCapture = null;
      _voiceAudioCaptureFailed = true;
      try {
        await capture.dispose();
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(
          '[voice-note-audio] event=recording_start_failed error_type=${error.runtimeType}',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 76, left: 16, right: 16),
            content: Text('Audio recording failed.'),
          ),
        );
      }
    }
  }

  void _showAudioCaptureFailure() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 76, left: 16, right: 16),
          content: Text('Audio recording failed.'),
        ),
      );
    }
  }

  Future<void> _stopVoiceAudioCapture() {
    final Future<void>? existing = _voiceAudioStopInFlight;
    if (existing != null) return existing;
    final Future<void> operation = _finishVoiceAudioCapture();
    _voiceAudioStopInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_voiceAudioStopInFlight, operation)) {
        _voiceAudioStopInFlight = null;
      }
    });
  }

  Future<void> _finishVoiceAudioCapture() async {
    if (_voiceMode == _VoiceMode.conversation) {
      _diag('event=finish_audio_capture_requested');
    } else {
      _recordDiag(
        'event=record_stop_requested active=${_activeVoiceAudioCapture != null}',
      );
    }
    final Future<void>? starting = _voiceAudioStartInFlight;
    if (starting != null) await starting;
    final VoiceNoteAudioCapture? capture = _activeVoiceAudioCapture;
    if (_voiceMode == _VoiceMode.conversation) {
      _diag(
        'event=finish_audio_capture_source',
        details: 'active=${capture != null}',
      );
    } else if (capture == null) {
      _recordDiag(
        'event=record_stop_completed recording_active=false audio_segments=${_voiceAudioSegments.length}',
      );
    }
    if (capture == null) return;
    _activeVoiceAudioCapture = null;
    try {
      final VoiceAudioSegment segment = await capture.stop();
      _voiceAudioSegments.add(segment);
      if (kDebugMode) {
        debugPrint(
          '[voice-note-audio] event=recording_finalized duration_ms=${segment.duration.inMilliseconds} file_size_bytes=${segment.fileSizeBytes}',
        );
      }
      if (_voiceMode == _VoiceMode.record) {
        _recordDiag(
          'event=record_stop_completed duration_ms=${segment.duration.inMilliseconds} file_size_bytes=${segment.fileSizeBytes}',
        );
      }
    } catch (error) {
      _voiceAudioCaptureFailed = true;
      await _discardFinalizedVoiceAudioSegments();
      if (kDebugMode) {
        debugPrint(
          '[voice-note-audio] event=recording_finalize_failed error_type=${error.runtimeType}',
        );
      }
      if (_voiceMode == _VoiceMode.record) {
        _recordDiag(
          'event=record_stop_failed error_type=${error.runtimeType}',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 76, left: 16, right: 16),
            content: Text(
              'Audio recording failed. Your transcript or conversation is still available to save.',
            ),
          ),
        );
      }
    } finally {
      try {
        await capture.dispose();
      } catch (_) {}
    }
  }

  Future<void>? _voiceAudioStartInFlight;

  List<String> get _voiceAudioPaths => _voiceAudioSegments
      .map((VoiceAudioSegment segment) => segment.path)
      .toList(growable: false);

  Future<void> _discardFinalizedVoiceAudioSegments() async {
    final List<VoiceAudioSegment> segments = List<VoiceAudioSegment>.from(
      _voiceAudioSegments,
    );
    _voiceAudioSegments.clear();
    for (final VoiceAudioSegment segment in segments) {
      try {
        await File(segment.path).delete();
      } catch (_) {}
    }
  }

  Duration get _voiceAudioDuration => _voiceAudioSegments.fold<Duration>(
    Duration.zero,
    (Duration total, VoiceAudioSegment segment) => total + segment.duration,
  );

  int get _voiceAudioFileSizeBytes => _voiceAudioSegments.fold<int>(
    0,
    (int total, VoiceAudioSegment segment) => total + segment.fileSizeBytes,
  );

  Future<void> _closeAfterVoiceNoteSave(Note note) async {
    if (!mounted) return;
    final String? category = note.category;
    // The feed underneath this route uses the same cubit.
    if (category != null && category.trim().isNotEmpty) {
      _latestNoteCubit.selectCategory(category);
      final LatestNoteState state = _latestNoteCubit.state;
      debugPrint(
        '[note-category] event=category_state_set '
        'matches=${state.selectedCategory?.toLowerCase() == category.trim().toLowerCase()} '
        'saved_note_visible=${state.filteredNotes.any((item) => item.id == note.id)}',
      );
    }
    _allowPop = true;
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(note);
  }

  Future<void> _saveLocalAudioReference(Note note) async {
    if (note.localAudioPaths.isEmpty && !note.audioRecordingFailed) return;
    await _localNoteAudioStore.save(
      note.id,
      LocalNoteAudioReference(
        paths: note.localAudioPaths,
        duration: note.duration ?? Duration.zero,
        fileSizeBytes: note.localAudioFileSizeBytes ?? 0,
        recordingFailed: note.audioRecordingFailed,
      ),
    );
  }

  void _clearVoiceAudioSession() {
    _voiceAudioSegments.clear();
    _voiceAudioCaptureFailed = false;
    _voiceAudioCaptureAttempted = false;
  }

  Future<void> _discardVoiceAudio() async {
    await _stopVoiceAudioCapture();
    for (final VoiceAudioSegment segment in _voiceAudioSegments) {
      try {
        await File(segment.path).delete();
      } catch (_) {}
    }
    _clearVoiceAudioSession();
    final String? pendingId = _pendingSaveId;
    if (pendingId != null) {
      try {
        await _localNoteAudioStore.remove(pendingId);
      } catch (_) {}
    }
  }

  bool _isVoiceActive = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A permission prompt can briefly take focus during microphone startup.
    // Release the mic when the app is actually hidden or backgrounded.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_pauseActiveServices());
    }
  }

  Future<void> _pauseActiveServices() async {
    final SttAdapter adapter = _activeSttAdapter;
    if (_transcriptState.isRecording && !_transcriptState.isPaused) {
      _transcriptState.pauseRecording();
      await adapter.stop();
    } else if (_voiceMode == _VoiceMode.conversation) {
      _conversationVoiceSession.value = false;
      if (adapter.status == SttStatus.listening ||
          adapter.status == SttStatus.starting) {
        await adapter.stop();
      }
    }
    await _stopVoiceAudioCapture();
  }

  Future<void> _stopActiveServices({bool discardAudio = false}) async {
    final SttAdapter adapter = _activeSttAdapter;
    _conversationVoiceSession.value = false;
    _isVoiceActive = false;
    if (_transcriptState.isRecording ||
        adapter.status == SttStatus.listening ||
        adapter.status == SttStatus.starting) {
      _transcriptState.stopRecording();
      await adapter.stop();
    }
    await _stopVoiceAudioCapture();
    if (discardAudio) await _discardVoiceAudio();
    if (_conversationSession.isConnected) {
      _conversationSession.setStatus(ConversationStatus.idle);
    }
  }

  void _onTabChanged(_Tab t) {
    if (_isVoiceActive) return;
    if (_tab != t) {
      unawaited(_pauseActiveServices());
      setState(() => _tab = t);
    }
  }

  Future<void> _onVoiceModeChanged(_VoiceMode m) async {
    if (_isVoiceActive || _voiceModeChangeInProgress || _voiceMode == m) {
      return;
    }
    _voiceModeChangeInProgress = true;
    try {
      await _pauseActiveServices();
      // Release both logical recognizers before transferring mode ownership.
      await _recordSttAdapter.stop();
      if (!identical(_recordSttAdapter, _conversationSttAdapter)) {
        await _conversationSttAdapter.stop();
      }
      if (mounted) {
        _recordSttAdapter.beginSession();
        if (!identical(_recordSttAdapter, _conversationSttAdapter)) {
          _conversationSttAdapter.beginSession();
        }
        setState(() => _voiceMode = m);
      }
    } finally {
      _voiceModeChangeInProgress = false;
    }
  }

  Future<void> _onClose() => _confirmClose();

  Future<void> _confirmClose() async {
    if (_finishInProgress || _closeInProgress) return;
    _closeInProgress = true;
    try {
      final bool hasDraft =
          _transcriptState.displayText.trim().isNotEmpty ||
          _voiceAudioCaptureAttempted ||
          _voiceAudioSegments.isNotEmpty;
      final bool hasConversation = _conversationSession.messages.any(
        (message) => message.text.trim().isNotEmpty,
      );
      if (hasDraft || hasConversation) {
        final bool discard =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Discard this draft?'),
                content: const Text(
                  'This unsaved transcript or conversation will be removed.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep editing'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!discard || !mounted) return;
        _transcriptState.clear();
        _conversationSession.clear();
      }
      await _stopActiveServices(discardAudio: true);
      _pendingSaveId = null;
      _allowPop = true;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } finally {
      _closeInProgress = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _conversationVoiceSession.removeListener(
      _onConversationVoiceSessionChanged,
    );
    _conversationGeneration++;
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _stopActiveServices(discardAudio: true);
    _draftController.dispose();
    _draftFocus.dispose();
    if (_ownsTranscriptState) _transcriptState.dispose();
    if (_ownsSttAdapters) {
      _recordSttAdapter.dispose();
      _conversationSttAdapter.dispose();
    }
    if (_ownsConversationSession) _conversationSession.dispose();
    if (_ownsLatestNoteCubit) await _latestNoteCubit.close();
    _conversationVoiceSession.dispose();
  }

  String? _currentUserId() {
    final String? explicitUserId = widget.userId;
    if (explicitUserId != null && explicitUserId.isNotEmpty) {
      return explicitUserId;
    }
    if (locator.isRegistered<UserCubit>()) {
      final String? id = locator<UserCubit>().state?.id;
      if (id != null && id.isNotEmpty) return id;
    }
    if (SupabaseConfig.isConfigured) {
      try {
        return sb.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _finishRecord() async {
    if (_finishInProgress) {
      _recordDiag('event=record_save_skipped reason=already_in_progress');
      return;
    }
    _recordDiag('event=record_save_flow_started');
    _finishInProgress = true;
    try {
      await _stopVoiceAudioCapture();
      if (!mounted) return;
      final String transcript = _transcriptState.displayText;
      _recordDiag(
        'event=record_save_context transcript_present=${transcript.trim().isNotEmpty} audio_segments=${_voiceAudioSegments.length}',
      );
      if (transcript.trim().isEmpty &&
          _voiceAudioSegments.isEmpty &&
          !_voiceAudioCaptureAttempted) {
        _recordDiag(
          'event=record_save_skipped reason=no_recording_or_transcript',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('There is no recording or transcript to save yet.'),
          ),
        );
        return;
      }

      final String? category = await showDialog<String>(
        context: context,
        builder: (context) => _CategoryDialog(
          categories: _latestNoteCubit.state.categories,
        ),
      );
      if (!mounted || category == null) {
        _recordDiag('event=record_save_skipped reason=category_not_selected');
        return;
      }

      final String? userId = _currentUserId();
      if (userId == null || userId.isEmpty) {
        _recordDiag('event=record_save_skipped reason=missing_user');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to save this note.')),
        );
        return;
      }

      final String title = transcript.trim().isEmpty
          ? 'Voice note'
          : _titleFromTranscript(transcript);
      final String preview = transcript.trim().isEmpty
          ? ''
          : transcript.length > 180
          ? '${transcript.substring(0, 180).trimRight()}…'
          : transcript;
      final Note note = Note(
        id: _pendingSaveId ??= Note.newId(),
        userId: userId,
        title: title,
        preview: preview,
        transcript: transcript.trim().isEmpty ? null : transcript,
        createdAt: DateTime.now(),
        category: category,
        categorySource: CategorySource.user,
        localAudioPaths: _voiceAudioPaths,
        localAudioFileSizeBytes: _voiceAudioSegments.isEmpty
            ? null
            : _voiceAudioFileSizeBytes,
        duration: _voiceAudioSegments.isEmpty ? null : _voiceAudioDuration,
        audioRecordingFailed: _voiceAudioCaptureFailed,
      );

      try {
        _recordDiag(
          'event=record_note_save_started transcript_present=${transcript.trim().isNotEmpty} audio_segments=${_voiceAudioSegments.length}',
        );
        await _latestNoteCubit.saveNote(note);
        _recordDiag('event=record_note_save_succeeded');
      } catch (error) {
        _recordDiag(
          'event=record_note_save_failed error_type=${error.runtimeType}',
        );
        if (error is sb.PostgrestException) {
          _recordDiag(
            'event=record_note_save_postgrest code=${_redactRecordPostgrestField(error.code ?? '', note)} message=${_redactRecordPostgrestField(error.message, note)} details=${_redactRecordPostgrestField(error.details?.toString() ?? '', note)} hint=${_redactRecordPostgrestField(error.hint?.toString() ?? '', note)}',
          );
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(bottom: 76, left: 16, right: 16),
              content: Text(
                'Could not save the note. Your draft and recording are still here; tap Finish note to retry.',
              ),
            ),
          );
        }
        return;
      }
      try {
        _recordDiag('event=record_audio_reference_save_started');
        await _saveLocalAudioReference(note);
        _recordDiag('event=record_audio_reference_save_succeeded');
      } catch (error) {
        _recordDiag(
          'event=record_audio_reference_save_failed error_type=${error.runtimeType}',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(bottom: 76, left: 16, right: 16),
              content: Text(
                'The note was saved, but its recording could not be attached. Tap Finish note to retry; the recording is still here.',
              ),
            ),
          );
        }
        return;
      }

      _recordDiag('event=record_save_flow_succeeded');
      _transcriptState.clear();
      _clearVoiceAudioSession();
      _pendingSaveId = null;
      await _closeAfterVoiceNoteSave(note);
    } finally {
      _finishInProgress = false;
    }
  }

  Future<void> _finishTypedNote() async {
    if (_finishInProgress) return;
    _recordTypeDiag('event=type_save_started');
    _finishInProgress = true;
    try {
      final String text = _draftController.text.trim();
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter some text before saving.')),
        );
        return;
      }

      final String? category = await showDialog<String>(
        context: context,
        builder: (context) => _CategoryDialog(
          categories: _latestNoteCubit.state.categories,
        ),
      );
      if (!mounted || category == null) return;

      final String? userId = _currentUserId();
      if (userId == null || userId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to save this note.')),
        );
        return;
      }

      final String preview = text.length > 180
          ? '${text.substring(0, 180).trimRight()}…'
          : text;
      final Note note = Note(
        id: _pendingSaveId ??= Note.newId(),
        userId: userId,
        title: _titleFromTranscript(text),
        preview: preview,
        transcript: text,
        createdAt: DateTime.now(),
        category: category,
        categorySource: CategorySource.user,
      );
      try {
        await _latestNoteCubit.saveNote(note);
        _recordTypeDiag('event=type_save_succeeded');
      } catch (error) {
        if (kDebugMode) {
          _recordTypeDiag(
            'event=type_save_failed error_type=${error.runtimeType}',
          );
          if (error is sb.PostgrestException) {
            _recordTypeDiag(
              'event=type_save_failed_postgrest code=${_redactRecordPostgrestField(error.code ?? '', note)} message=${_redactRecordPostgrestField(error.message, note)} details=${_redactRecordPostgrestField(error.details?.toString() ?? '', note)} hint=${_redactRecordPostgrestField(error.hint?.toString() ?? '', note)}',
            );
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not save the note. Your text is still here; try again.',
              ),
            ),
          );
        }
        return;
      }

      _draftController.clear();
      _pendingSaveId = null;
      if (mounted) {
        _allowPop = true;
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.of(context).pop(note);
      }
    } finally {
      _finishInProgress = false;
    }
  }

  void _recordTypeDiag(String event) {
    if (kDebugMode) debugPrint('[type-note] $event');
  }

  Future<void> _finishConversation() async {
    if (_finishInProgress) return;
    _diag('event=finish_conversation_requested');
    if (_aiRequestInFlight) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Wait for the AI reply before finishing.'),
        ),
      );
      return;
    }
    _conversationVoiceSession.value = false;
    if (_conversationSttAdapter.status == SttStatus.listening ||
        _conversationSttAdapter.status == SttStatus.starting) {
      _diag('event=finish_stt_stop_requested');
      await _conversationSttAdapter.stop();
      _diag('event=finish_stt_stop_completed');
    }
    await _stopVoiceAudioCapture();
    _diag(
      'event=finish_audio_capture_stopped',
      details: 'segments=${_voiceAudioSegments.length}',
    );
    if (!mounted) return;
    final List<ConversationMessage> messages = _conversationSession.messages
        .where(
          (message) =>
              !message.isPartial &&
              !message.isPending &&
              !message.isError &&
              message.text.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (messages.isEmpty) {
      _diag('event=finish_conversation_rejected reason=no_final_messages');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is no conversation to save yet.')),
      );
      return;
    }

    _finishInProgress = true;
    try {
      final String transcript = messages
          .map(
            (message) =>
                '${message.speaker == ConversationSpeaker.user ? 'User' : 'AI'}: ${message.text}',
          )
          .join('\n');
      final String? category = await showDialog<String>(
        context: context,
        builder: (context) => _CategoryDialog(
          categories: _latestNoteCubit.state.categories,
        ),
      );
      _diag('event=finish_category_result selected=${category != null}');
      if (!mounted || category == null) return;

      final String? userId = _currentUserId();
      _diag('event=conversation_save_user_id present=${userId != null}');
      if (userId == null || userId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to save this conversation.')),
        );
        return;
      }

      final String firstUserLine =
          messages
              .where((message) => message.speaker == ConversationSpeaker.user)
              .map((message) => message.text.trim())
              .firstOrNull ??
          'Conversation';
      final String preview = firstUserLine.length > 180
          ? '${firstUserLine.substring(0, 180).trimRight()}…'
          : firstUserLine;
      final Note note = Note(
        id: _pendingSaveId ??= Note.newId(),
        userId: userId,
        title: _titleFromTranscript(firstUserLine),
        preview: preview,
        transcript: transcript,
        conversationMessages: messages
            .map(
              (message) => <String, dynamic>{
                'id': message.id,
                'speaker': message.speaker.name,
                'text': message.text,
                'timestamp': message.timestamp.toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
        createdAt: DateTime.now(),
        category: category,
        categorySource: CategorySource.user,
        localAudioPaths: _voiceAudioPaths,
        localAudioFileSizeBytes: _voiceAudioSegments.isEmpty
            ? null
            : _voiceAudioFileSizeBytes,
        duration: _voiceAudioSegments.isEmpty ? null : _voiceAudioDuration,
        audioRecordingFailed: _voiceAudioCaptureFailed,
      );
      try {
        await _latestNoteCubit.saveNote(note);
        _diag('event=conversation_save_note_complete');
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not save the conversation. It is still here; try again.',
              ),
            ),
          );
        }
        return;
      }
      try {
        _diag('event=conversation_audio_attach_requested');
        await _saveLocalAudioReference(note);
        _diag('event=conversation_audio_attach_complete');
      } catch (_) {
        _diag('event=conversation_audio_attach_failed');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The conversation was saved, but its recording could not be attached. Tap Finish conversation to retry; the file and note are retained.',
              ),
            ),
          );
        }
        return;
      }

      _conversationSession.clear();
      _conversationVoiceSession.value = false;
      _clearVoiceAudioSession();
      _pendingSaveId = null;
      await _closeAfterVoiceNoteSave(note);
    } finally {
      _finishInProgress = false;
    }
  }

  String _titleFromTranscript(String transcript) {
    final String firstLine = transcript
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => 'New note');
    return firstLine.length <= 72
        ? firstLine
        : '${firstLine.substring(0, 69).trimRight()}…';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool onVoiceTab = _tab == _Tab.voice;

    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _confirmClose();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: cs.surface,
          leading: IconButton(
            icon: Icon(Icons.close_rounded, color: cs.onSurface),
            tooltip: 'Close',
            onPressed: () => _onClose(),
          ),
          title: Text(
            'New note',
            style: GoogleFonts.unbounded(
              textStyle: Theme.of(context).textTheme.titleMedium,
              fontWeight: FontWeight.w700,
            ),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),

              // ── Top segmented switch: Voice | Type ─────────────────────────
              _SegmentedSwitch<_Tab>(
                enabled: !_isVoiceActive,
                value: _tab,
                options: const <_Tab>[_Tab.voice, _Tab.type],
                labelOf: (t) => t == _Tab.voice ? 'Voice' : 'Type',
                onChanged: _onTabChanged,
              ),

              const SizedBox(height: 12),

              // ── Content area ───────────────────────────────────────────────
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: onVoiceTab
                      ? _VoiceTwoStateLayout(
                          key: const ValueKey<_Tab>(_Tab.voice),
                          voiceMode: _voiceMode,
                          onVoiceModeChanged: _onVoiceModeChanged,
                          transcriptState: _transcriptState,
                          sttAdapter: _activeSttAdapter,
                          conversationSession: _conversationSession,
                          conversationVoiceSession: _conversationVoiceSession,
                          aiRequestInFlight: _aiRequestInFlight,
                          onActiveStateChanged: (bool active) {
                            if (mounted) {
                              setState(() {
                                _isVoiceActive =
                                    _voiceMode == _VoiceMode.conversation
                                    ? _conversationVoiceSession.value
                                    : active;
                              });
                            }
                          },
                          transcriptRevealed: _transcriptRevealed,
                          onTranscriptRevealed: (bool revealed) {
                            if (mounted && _transcriptRevealed != revealed) {
                              setState(() => _transcriptRevealed = revealed);
                            }
                          },
                          onFinishRequested: _finishRecord,
                          onFinishConversation: _finishConversation,
                          onStopPlayback: _stopAppPlaybackForCapture,
                          onStartAudioCapture: _startVoiceAudioCapture,
                          onStopAudioCapture: _stopVoiceAudioCapture,
                          hasPcmAudioCapture: () =>
                              _activeVoiceAudioCapture
                                  is PcmVoiceNoteAudioCapture,
                          onConversationTurn: _sendConversationTurn,
                          onRetryConversation: _retryConversationReply,
                          onDiagnostic: _diag,
                          onListenStartRequested:
                              _nextConversationListenGeneration,
                        )
                      : _TypeTabContent(
                          key: const ValueKey<_Tab>(_Tab.type),
                          controller: _draftController,
                          focusNode: _draftFocus,
                          onSave: _finishTypedNote,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable Two-State Voice Layout (Record & Conversation Modes)
// ─────────────────────────────────────────────────────────────────────────────

class _VoiceTwoStateLayout extends StatefulWidget {
  const _VoiceTwoStateLayout({
    super.key,
    required this.voiceMode,
    required this.onVoiceModeChanged,
    required this.transcriptState,
    required this.sttAdapter,
    required this.conversationSession,
    required this.conversationVoiceSession,
    required this.aiRequestInFlight,
    required this.onActiveStateChanged,
    required this.transcriptRevealed,
    required this.onTranscriptRevealed,
    required this.onFinishRequested,
    required this.onFinishConversation,
    required this.onStopPlayback,
    required this.onStartAudioCapture,
    required this.onStopAudioCapture,
    required this.hasPcmAudioCapture,
    required this.onConversationTurn,
    required this.onRetryConversation,
    required this.onDiagnostic,
    required this.onListenStartRequested,
  });

  final _VoiceMode voiceMode;
  final ValueChanged<_VoiceMode> onVoiceModeChanged;
  final TranscriptState transcriptState;
  final SttAdapter sttAdapter;
  final ConversationSession conversationSession;
  final ValueNotifier<bool> conversationVoiceSession;
  final bool aiRequestInFlight;
  final ValueChanged<bool> onActiveStateChanged;
  final bool transcriptRevealed;
  final ValueChanged<bool> onTranscriptRevealed;
  final Future<void> Function() onFinishRequested;
  final Future<void> Function() onFinishConversation;
  final Future<void> Function() onStopPlayback;
  final Future<void> Function() onStartAudioCapture;
  final Future<void> Function() onStopAudioCapture;
  final bool Function() hasPcmAudioCapture;
  final Future<void> Function(
    String userMessageId,
    String text, {
    int? listenGeneration,
    Stopwatch? finalToRequestTimer,
  })
  onConversationTurn;
  final Future<void> Function(String userMessageId) onRetryConversation;
  final ConversationDiagnosticCallback onDiagnostic;
  final int Function() onListenStartRequested;

  @override
  State<_VoiceTwoStateLayout> createState() => _VoiceTwoStateLayoutState();
}

class _VoiceTwoStateLayoutState extends State<_VoiceTwoStateLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _isActive = false;
  bool _isStarting = false;
  bool _conversationHasNewTurn = false;
  bool _conversationSubmissionInProgress = false;
  bool _awaitingFinalResult = false;
  Timer? _finalResultGraceTimer;
  String? _submittedConversationMessageId;
  String _lastHandledConversationFinal = '';
  String _lastHandledConversationPartial = '';
  Stopwatch? _listenTimer;
  Stopwatch? _finalToRequestTimer;
  int _listenGeneration = 0;
  int? _sttSessionGeneration;
  bool _currentConversationListenAcknowledged = false;
  int? _recordSessionGeneration;
  int? _recordListenGeneration;
  bool _recordTranscriptionReady = false;
  bool _recordFinalConsumed = false;
  String? _recordTranscriptionError;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    if (widget.transcriptRevealed) _controller.value = 1;
    _controller.addListener(() {
      setState(() {});
    });
    widget.sttAdapter.addListener(_onSttChanged);
    widget.sttAdapter.setDiagnosticLogger(
      _onAdapterDiagnostic,
      listenGenerationProvider: () => _listenGeneration,
    );
    widget.conversationVoiceSession.addListener(_onConversationSessionChanged);
  }

  void _onAdapterDiagnostic(
    String event, {
    int? listenGeneration,
  }) {
    widget.onDiagnostic(event, listenGeneration: listenGeneration);
  }

  void _diag(String event, {String? details}) {
    widget.onDiagnostic(
      event,
      listenGeneration: _listenGeneration,
      details: details,
    );
  }

  void _onConversationSessionChanged() {
    if (widget.conversationVoiceSession.value) return;
    _finalResultGraceTimer?.cancel();
    _finalResultGraceTimer = null;
    _awaitingFinalResult = false;
    _isActive = false;
    if (mounted) setState(() {});
  }

  void _onSttChanged() {
    if (widget.voiceMode == _VoiceMode.conversation) {
      final String finalText = widget.sttAdapter.finalText;
      final String partialText = widget.sttAdapter.partialText;
      final bool hasResult = finalText.isNotEmpty || partialText.isNotEmpty;
      if (!widget.conversationVoiceSession.value) {
        if (hasResult) {
          _diag('event=result_rejected reason=session_inactive');
        }
        return;
      }
      if (widget.sttAdapter.status == SttStatus.listening &&
          widget.sttAdapter.currentSessionGeneration == _sttSessionGeneration &&
          widget.sttAdapter.currentListenGeneration == _listenGeneration) {
        _currentConversationListenAcknowledged = true;
      }
      if (hasResult) {
        if (widget.sttAdapter.resultSessionGeneration !=
            _sttSessionGeneration) {
          _diag('event=result_rejected reason=stale_session_generation');
          widget.sttAdapter.clearCurrentResult();
          return;
        }
        if (widget.sttAdapter.resultListenGeneration != _listenGeneration) {
          _diag('event=result_rejected reason=stale_listen_generation');
          widget.sttAdapter.clearCurrentResult();
          return;
        }
        if (!_currentConversationListenAcknowledged) {
          _diag('event=result_rejected reason=listen_not_acknowledged');
          widget.sttAdapter.clearCurrentResult();
          return;
        }
      }
      if (finalText.isNotEmpty && finalText != _lastHandledConversationFinal) {
        _clearFinalResultWait();
        _lastHandledConversationFinal = finalText;
        _lastHandledConversationPartial = '';
        _finalToRequestTimer = Stopwatch()..start();
        _diag(
          'event=result_accepted reason=new_final',
          details:
              'listen_elapsed_ms=${_listenTimer?.elapsedMilliseconds ?? -1}',
        );
        widget.conversationSession.finalizeUserUtterance(finalText);
        _conversationHasNewTurn = true;
        _submitLatestConversationTurn();
      } else if (partialText.isNotEmpty) {
        if (partialText != _lastHandledConversationPartial) {
          _diag('event=result_accepted reason=partial_update');
        } else {
          _diag('event=result_rejected reason=duplicate_partial_update');
        }
        _lastHandledConversationPartial = partialText;
        widget.conversationSession.updateUserPartial(partialText);
        _conversationHasNewTurn = true;
      } else if (finalText.isNotEmpty &&
          finalText == _lastHandledConversationFinal) {
        _diag('event=result_rejected reason=duplicate_final');
      }
      if (widget.sttAdapter.status == SttStatus.stopped ||
          widget.sttAdapter.status == SttStatus.error) {
        _diag(
          'event=recognizer_state_observed status=${widget.sttAdapter.status.name}',
          details:
              'turn_pending=${_conversationHasNewTurn || _conversationSubmissionInProgress}',
        );
      }
      if (_isStarting && widget.sttAdapter.status == SttStatus.stopped) {
        _diag('event=stopped_status_ignored reason=listen_starting');
        return;
      }
      if (widget.sttAdapter.status == SttStatus.stopped &&
          !_conversationSubmissionInProgress &&
          mounted) {
        if (widget.sttAdapter.finalText.isEmpty) {
          if (widget.sttAdapter.lastErrorCode.toLowerCase().contains(
            'error_no_match',
          )) {
            _restartAfterSilentEnd();
          } else {
            _waitForFinalResult();
          }
        } else {
          widget.conversationSession.setStatus(ConversationStatus.idle);
        }
        if (_isActive) {
          _isActive = false;
          widget.onActiveStateChanged(false);
          setState(() {});
        }
      }
      if (widget.sttAdapter.status == SttStatus.error) {
        _clearFinalResultWait();
        widget.conversationSession.setError(
          widget.sttAdapter.lastError.isEmpty
              ? 'Speech recognition failed. Tap Start conversation to try again.'
              : widget.sttAdapter.lastError,
        );
        if (_isActive && mounted) {
          _isActive = false;
          widget.onActiveStateChanged(false);
          setState(() {});
        }
      }
      return;
    }
    _onRecordSttChanged();
  }

  void _recordTranscriptDiag(String event) {
    if (kDebugMode) debugPrint('[voice-note-audio] event=$event');
  }

  void _showRecordTranscriptionError(
    String message, {
    String code = 'unknown',
  }) {
    _recordTranscriptionReady = false;
    _recordTranscriptDiag('record_transcript_error code=$code');
    if (_recordTranscriptionError != null || !mounted) return;
    setState(() => _recordTranscriptionError = message);
  }

  void _onRecordSttChanged() {
    if (widget.sttAdapter.status == SttStatus.error && !_isActive) return;
    final String finalText = widget.sttAdapter.finalText;
    final String partialText = widget.sttAdapter.partialText;
    final int? resultSession = widget.sttAdapter.resultSessionGeneration;
    final int? resultListen = widget.sttAdapter.resultListenGeneration;
    if (finalText.isNotEmpty &&
        ((resultSession != null && resultSession != _recordSessionGeneration) ||
            (resultListen != null &&
                resultListen != _recordListenGeneration))) {
      return;
    }
    if (partialText.isNotEmpty) {
      widget.transcriptState.updatePartial(partialText);
    }
    if (finalText.isNotEmpty && !_recordFinalConsumed) {
      _recordFinalConsumed = true;
      widget.transcriptState.appendFinalSegment(finalText);
      _recordTranscriptDiag(
        'record_transcript_segment length=${finalText.length}',
      );
    }
    if (widget.sttAdapter.status == SttStatus.error) {
      if (finalText.isEmpty && partialText.isNotEmpty) {
        widget.transcriptState.appendFinalSegment(partialText);
        _recordTranscriptDiag(
          'record_transcript_segment length=${partialText.length}',
        );
      }
      _showRecordTranscriptionError(
        'Speech recognition stopped.',
        code: widget.sttAdapter.lastErrorCode.isEmpty
            ? 'recognition_error'
            : widget.sttAdapter.lastErrorCode,
      );
      return;
    }
    if (widget.sttAdapter.status == SttStatus.stopped &&
        finalText.isEmpty &&
        partialText.isNotEmpty &&
        !_recordFinalConsumed) {
      _recordFinalConsumed = true;
      widget.transcriptState.appendFinalSegment(partialText);
      _recordTranscriptDiag(
        'record_transcript_segment length=${partialText.length}',
      );
    }
    if (widget.sttAdapter.status == SttStatus.stopped &&
        _isActive &&
        !_isStarting &&
        widget.transcriptState.isRecording &&
        !widget.transcriptState.isPaused &&
        _recordTranscriptionReady) {
      unawaited(_restartRecordRecognition());
    }
  }

  Future<void> _startRecordRecognition({bool firstStart = false}) async {
    if (!mounted || !_isActive || !_recordTranscriptionReady) return;
    final int? session = _recordSessionGeneration;
    if (session == null) return;
    _isStarting = true;
    try {
      _recordListenGeneration = widget.onListenStartRequested();
      _recordFinalConsumed = false;
      if (firstStart) _recordTranscriptDiag('record_transcript_start');
      await widget.sttAdapter.startForSession(
        session,
        _recordListenGeneration!,
      );
      if (widget.sttAdapter.status != SttStatus.listening) {
        _showRecordTranscriptionError(
          'Speech recognition could not start.',
          code: widget.sttAdapter.lastErrorCode.isEmpty
              ? 'start_failed'
              : widget.sttAdapter.lastErrorCode,
        );
      }
    } catch (error) {
      _showRecordTranscriptionError(
        'Speech recognition could not start.',
        code: error.runtimeType.toString(),
      );
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _restartRecordRecognition() async {
    await _startRecordRecognition();
  }

  void _waitForFinalResult() {
    if (_awaitingFinalResult) return;
    _awaitingFinalResult = true;
    widget.conversationSession.setStatus(ConversationStatus.finalizing);
    _finalResultGraceTimer = Timer(const Duration(milliseconds: 800), () {
      _finalResultGraceTimer = null;
      if (!mounted) return;
      _awaitingFinalResult = false;
      final String finalText = widget.sttAdapter.finalText;
      final String partialText = widget.sttAdapter.partialText;
      final String result = finalText.isNotEmpty ? finalText : partialText;
      if (result.isNotEmpty) {
        _finalToRequestTimer = Stopwatch()..start();
        _diag(
          'event=result_accepted reason=status_grace_finalization',
        );
        if (finalText.isNotEmpty) {
          _lastHandledConversationFinal = finalText;
        }
        widget.conversationSession.finalizeUserUtterance(result);
        _conversationHasNewTurn = true;
        _submitLatestConversationTurn();
      } else {
        _diag(
          'event=final_result_grace_expired result=empty action=silent_restart',
        );
        widget.conversationSession.setStatus(ConversationStatus.idle);
        _restartAfterSilentEnd();
      }
    });
  }

  void _restartAfterSilentEnd() {
    _clearFinalResultWait();
    if (!_canResumeConversation ||
        _conversationSubmissionInProgress ||
        widget.aiRequestInFlight ||
        _isStarting) {
      return;
    }
    if (_isActive) {
      _isActive = false;
      widget.onActiveStateChanged(false);
    }
    _diag('event=silent_restart_requested');
    unawaited(_startRecognitionForNextTurn());
  }

  void _clearFinalResultWait() {
    _finalResultGraceTimer?.cancel();
    _finalResultGraceTimer = null;
    if (_awaitingFinalResult) {
      _awaitingFinalResult = false;
      widget.onActiveStateChanged(false);
    }
  }

  ConversationMessage? get _lastConversationUserMessage {
    final List<ConversationMessage> messages =
        widget.conversationSession.messages;
    return messages.isNotEmpty &&
            messages.last.speaker == ConversationSpeaker.user
        ? messages.last
        : null;
  }

  Future<void> _submitLatestConversationTurn() async {
    final ConversationMessage? message = _lastConversationUserMessage;
    if (message == null ||
        message.isPartial ||
        !widget.conversationVoiceSession.value ||
        _conversationSubmissionInProgress ||
        message.id == _submittedConversationMessageId) {
      return;
    }
    _submittedConversationMessageId = message.id;
    _conversationHasNewTurn = false;
    _conversationSubmissionInProgress = true;
    try {
      _isActive = false;
      if (mounted) setState(() {});
      final Stopwatch stopTimer = Stopwatch()..start();
      await widget.sttAdapter.stop();
      _diag(
        'event=stop_for_submission_complete',
        details:
            'status=${widget.sttAdapter.status.name} stop_elapsed_ms=${stopTimer.elapsedMilliseconds}',
      );
      if (mounted) {
        final Stopwatch finalToRequestTimer =
            _finalToRequestTimer ?? Stopwatch();
        if (!finalToRequestTimer.isRunning) finalToRequestTimer.start();
        _finalToRequestTimer = null;
        await widget.onConversationTurn(
          message.id,
          message.text,
          listenGeneration: _listenGeneration,
          finalToRequestTimer: finalToRequestTimer,
        );
      }
    } finally {
      _conversationSubmissionInProgress = false;
      if (_canResumeConversation &&
          widget.sttAdapter.status != SttStatus.error) {
        await _startRecognitionForNextTurn();
      }
    }
  }

  bool get _canResumeConversation =>
      mounted &&
      widget.voiceMode == _VoiceMode.conversation &&
      widget.conversationVoiceSession.value &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached;

  Future<void> _startRecognitionForNextTurn() async {
    if (!_canResumeConversation || _isStarting) return;
    if (widget.sttAdapter.status == SttStatus.listening) {
      _isActive = true;
      if (mounted) setState(() {});
      return;
    }
    _isStarting = true;
    _clearFinalResultWait();
    _lastHandledConversationFinal = '';
    _lastHandledConversationPartial = '';
    _conversationHasNewTurn = false;
    _currentConversationListenAcknowledged = false;
    try {
      final Stopwatch listenTimer = Stopwatch()..start();
      _listenTimer = listenTimer;
      _listenGeneration = widget.onListenStartRequested();
      _diag('event=restart_requested');
      final int sessionGeneration = _sttSessionGeneration ??= widget.sttAdapter
          .beginSession();
      await widget.sttAdapter.startForSession(
        sessionGeneration,
        _listenGeneration,
      );
      if (widget.sttAdapter.status == SttStatus.starting) {
        await _waitForRecognizerStart();
      }
      if (!_canResumeConversation) {
        if (widget.sttAdapter.status == SttStatus.listening) {
          await widget.sttAdapter.stop();
        }
        return;
      }
      if (widget.sttAdapter.status == SttStatus.listening) {
        _isActive = true;
        widget.conversationSession.setStatus(ConversationStatus.listening);
        _diag(
          'event=restart_acknowledged plugin_isListening=true',
          details: 'restart_call_elapsed_ms=${listenTimer.elapsedMilliseconds}',
        );
      } else {
        _diag(
          'event=restart_failed status=${widget.sttAdapter.status.name}',
          details: 'restart_call_elapsed_ms=${listenTimer.elapsedMilliseconds}',
        );
        widget.conversationSession.setError(
          widget.sttAdapter.lastError.isEmpty
              ? 'Speech recognition could not resume. Stop and start again to retry.'
              : widget.sttAdapter.lastError,
        );
      }
    } finally {
      _isStarting = false;
      if (mounted) setState(() {});
    }
  }

  Future<SttStatus> _waitForRecognizerStart() async {
    if (widget.sttAdapter.status != SttStatus.starting) {
      return widget.sttAdapter.status;
    }
    final Completer<SttStatus> started = Completer<SttStatus>();
    void onChanged() {
      final SttStatus status = widget.sttAdapter.status;
      if ((status == SttStatus.listening || status == SttStatus.error) &&
          !started.isCompleted) {
        started.complete(status);
      }
    }

    widget.sttAdapter.addListener(onChanged);
    try {
      return await started.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => widget.sttAdapter.status,
      );
    } finally {
      widget.sttAdapter.removeListener(onChanged);
    }
  }

  @override
  void didUpdateWidget(covariant _VoiceTwoStateLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sttAdapter, widget.sttAdapter)) {
      oldWidget.sttAdapter.removeListener(_onSttChanged);
      widget.sttAdapter.addListener(_onSttChanged);
      widget.sttAdapter.setDiagnosticLogger(
        _onAdapterDiagnostic,
        listenGenerationProvider: () => _listenGeneration,
      );
      _sttSessionGeneration = null;
      _currentConversationListenAcknowledged = false;
    }
    if (!oldWidget.transcriptRevealed && widget.transcriptRevealed) {
      _controller.forward();
    }
    if (oldWidget.voiceMode != widget.voiceMode && _isActive) {
      _isActive = false;
      _controller.reset();
      widget.onActiveStateChanged(false);
    }
    if (oldWidget.voiceMode != widget.voiceMode) {
      _sttSessionGeneration = null;
      _currentConversationListenAcknowledged = false;
      if (widget.voiceMode == _VoiceMode.record && !widget.transcriptRevealed) {
        _controller.reverse();
      } else if (widget.voiceMode == _VoiceMode.conversation &&
          widget.conversationSession.messages.isNotEmpty) {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    widget.sttAdapter.removeListener(_onSttChanged);
    widget.conversationVoiceSession.removeListener(
      _onConversationSessionChanged,
    );
    _finalResultGraceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startConversationVoiceSession() async {
    if (!widget.conversationSession.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sign in and configure the Supabase conversation service to continue.',
          ),
        ),
      );
      return;
    }
    if (widget.aiRequestInFlight || _isStarting) return;
    _conversationHasNewTurn = false;
    _lastHandledConversationFinal = '';
    _lastHandledConversationPartial = '';
    _clearFinalResultWait();
    _listenTimer = Stopwatch()..start();
    _sttSessionGeneration = widget.sttAdapter.beginSession();
    _currentConversationListenAcknowledged = false;
    widget.conversationVoiceSession.value = true;
    _isStarting = true;
    setState(() {});
    try {
      await widget.onStopPlayback();
      _diag('event=conversation_playback_stopped');
      final SttInitResult init = await widget.sttAdapter.initialize();
      _diag('event=conversation_stt_initialized result=${init.name}');
      if (!mounted || !widget.conversationVoiceSession.value) return;
      if (init != SttInitResult.ready) {
        widget.conversationSession.setError(
          widget.sttAdapter.lastError.isEmpty
              ? 'Speech recognition is unavailable on this device.'
              : widget.sttAdapter.lastError,
        );
        widget.conversationVoiceSession.value = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.sttAdapter.lastError)),
        );
        return;
      }
      // Initialize the recognizer first, but do not begin recognition until
      // the recorder has acquired the microphone.
      _diag('event=conversation_capture_start_requested');
      await widget.onStartAudioCapture();
      _diag('event=conversation_capture_start_completed');
      if (!mounted || !widget.conversationVoiceSession.value) {
        await widget.onStopAudioCapture();
        return;
      }
      _listenGeneration = widget.onListenStartRequested();
      _diag('event=listen_requested');
      await widget.sttAdapter.startForSession(
        _sttSessionGeneration!,
        _listenGeneration,
      );
      if (widget.sttAdapter.status == SttStatus.starting) {
        await _waitForRecognizerStart();
      }
      if (!mounted || !widget.conversationVoiceSession.value) {
        if (widget.sttAdapter.status == SttStatus.listening) {
          await widget.sttAdapter.stop();
        }
        return;
      }
      if (widget.sttAdapter.status == SttStatus.listening) {
        _isActive = true;
        _currentConversationListenAcknowledged = true;
        widget.conversationSession.setStatus(ConversationStatus.listening);
        _diag(
          'event=listen_acknowledged plugin_isListening=true',
          details:
              'listen_call_elapsed_ms=${_listenTimer?.elapsedMilliseconds ?? -1}',
        );
        _controller.forward();
      } else {
        await widget.onStopAudioCapture();
        widget.conversationSession.setError(
          widget.sttAdapter.lastError.isEmpty
              ? 'The recognizer did not start. Try again.'
              : widget.sttAdapter.lastError,
        );
        widget.conversationVoiceSession.value = false;
      }
    } catch (error) {
      if (widget.sttAdapter.status == SttStatus.listening ||
          widget.sttAdapter.status == SttStatus.starting) {
        await widget.sttAdapter.stop();
      }
      await widget.onStopAudioCapture();
      widget.conversationVoiceSession.value = false;
      widget.conversationSession.setError(
        'Could not start voice recognition (${error.runtimeType}).',
      );
    } finally {
      _isStarting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _stopConversationVoiceSession() async {
    widget.conversationVoiceSession.value = false;
    _finalResultGraceTimer?.cancel();
    _finalResultGraceTimer = null;
    _awaitingFinalResult = false;
    try {
      if (widget.sttAdapter.status == SttStatus.listening ||
          widget.sttAdapter.status == SttStatus.starting) {
        await widget.sttAdapter.stop();
      }
    } finally {
      await widget.onStopAudioCapture();
    }
    if (!mounted) return;
    _isActive = false;
    widget.conversationSession.setStatus(ConversationStatus.idle);
    setState(() {});
  }

  Future<void> _retryConversationFromBubble(String userMessageId) async {
    if (!widget.conversationVoiceSession.value ||
        _conversationSubmissionInProgress ||
        widget.aiRequestInFlight) {
      return;
    }
    _conversationSubmissionInProgress = true;
    if (_isActive) {
      _isActive = false;
      setState(() {});
      await widget.sttAdapter.stop();
    }
    await widget.onRetryConversation(userMessageId);
    _conversationSubmissionInProgress = false;
    if (_canResumeConversation) await _startRecognitionForNextTurn();
  }

  Future<void> _handleStartStop() async {
    if (widget.voiceMode == _VoiceMode.conversation) {
      if (widget.conversationVoiceSession.value) {
        await _stopConversationVoiceSession();
      } else if (!_controller.isAnimating && !widget.aiRequestInFlight) {
        await _startConversationVoiceSession();
      }
      return;
    }
    if (_isStarting || (_controller.isAnimating && !_isActive)) return;

    if (!_isActive &&
        widget.voiceMode == _VoiceMode.record &&
        widget.transcriptRevealed) {
      await widget.onFinishRequested();
      return;
    }

    if (!_isActive) {
      _isStarting = true;
      // Transition from IDLE -> ACTIVE
      if (widget.voiceMode == _VoiceMode.record) {
        widget.onTranscriptRevealed(true);
        _controller.forward();
        final bool pcmRecognizer = widget.sttAdapter is PcmInputSttAdapter;
        _recordTranscriptionReady = false;
        _recordTranscriptionError = null;
        try {
          await widget.onStopPlayback();
          if (pcmRecognizer) {
            _recordSessionGeneration = widget.sttAdapter.beginSession();
            try {
              final SttInitResult init = await widget.sttAdapter.initialize();
              if (init == SttInitResult.ready) {
                _recordTranscriptionReady = true;
              } else {
                _showRecordTranscriptionError(
                  'Speech recognition is unavailable.',
                  code: widget.sttAdapter.lastErrorCode.isEmpty
                      ? 'initialization_failed'
                      : widget.sttAdapter.lastErrorCode,
                );
              }
            } catch (error) {
              _showRecordTranscriptionError(
                'Speech recognition is unavailable.',
                code: error.runtimeType.toString(),
              );
            }
          } else {
            _showRecordTranscriptionError(
              'This recognizer cannot use the shared recording audio.',
              code: 'shared_pcm_not_supported',
            );
          }
          await widget.onStartAudioCapture();
          if (!mounted) return;
          widget.transcriptState.startRecording();
        } catch (_) {
          await widget.onStopAudioCapture();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Audio recording failed.')),
          );
        }
      }

      _isStarting = false;
      setState(() => _isActive = true);
      widget.onActiveStateChanged(true);
      _controller.forward();
      if (widget.voiceMode == _VoiceMode.record) {
        if (widget.hasPcmAudioCapture() && _recordTranscriptionReady) {
          await _startRecordRecognition(firstStart: true);
        }
      }
    } else {
      // Transition from ACTIVE -> IDLE
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (widget.voiceMode == _VoiceMode.record) {
        _isStarting = true;
        if (widget.sttAdapter.status == SttStatus.listening ||
            widget.sttAdapter.status == SttStatus.starting) {
          await widget.sttAdapter.stop();
        }
        await widget.onStopAudioCapture();
        widget.transcriptState.stopRecording();
        if (!mounted) return;
        _isStarting = false;
        setState(() => _isActive = false);
        widget.onActiveStateChanged(false);
        await widget.onFinishRequested();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    final double t = _controller.value;
    final double groupProgress = Curves.fastOutSlowIn.transform(t);
    final double orbScale = 1.0 - 0.20 * groupProgress;

    // Panel fade & slight 16dp upward slide starts at 30% progress
    final double panelFade = const Interval(
      0.3,
      1.0,
      curve: Curves.easeOut,
    ).transform(t);
    final double panelSlideProgress = const Interval(
      0.3,
      1.0,
      curve: Curves.easeOut,
    ).transform(t);
    final double panelSlideY = 16.0 * (1.0 - panelSlideProgress);

    final bool isRecord = widget.voiceMode == _VoiceMode.record;
    final bool isConnected = isRecord
        ? widget.transcriptState.isConnected
        : widget.conversationSession.isConnected;

    final String buttonLabel;
    final IconData buttonIcon;
    if (isRecord) {
      if (_isStarting && !_isActive) {
        buttonLabel = 'Starting…';
        buttonIcon = Icons.hourglass_top_rounded;
      } else if (_isActive) {
        buttonLabel = 'Stop & finish';
        buttonIcon = Icons.stop_rounded;
      } else {
        buttonLabel = widget.transcriptRevealed
            ? 'Finish note'
            : 'Start recording';
        buttonIcon = widget.transcriptRevealed
            ? Icons.check_rounded
            : Icons.mic_rounded;
      }
    } else {
      if (widget.conversationVoiceSession.value) {
        buttonLabel = 'Stop';
        buttonIcon = Icons.stop_rounded;
      } else {
        buttonLabel = 'Start conversation';
        buttonIcon = Icons.mic_rounded;
      }
    }

    final bool togglesEnabled =
        !widget.conversationVoiceSession.value &&
        !_isActive &&
        !_controller.isAnimating;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double totalHeight = constraints.maxHeight;
        final double bottomInset = MediaQuery.paddingOf(context).bottom;
        final double bottomBarHeight = 48.0 + bottomInset + 16.0;
        final double contentHeight = totalHeight - bottomBarHeight;

        const double groupHeight = 192.0; // 140 orb + 8 gap + 44 switch
        const double targetY = 8.0;
        final double centeredY = ((contentHeight - groupHeight) / 2).clamp(
          targetY,
          double.infinity,
        );
        final double currentTranslateY =
            (centeredY - targetY) * (1.0 - groupProgress);

        const double panelTop = targetY + groupHeight + 10.0;
        final double panelBottom = bottomBarHeight + 8.0;

        return Stack(
          children: [
            // ── Transcript / Chat Panel (reveals in active space) ──────────
            Positioned(
              top: panelTop,
              left: 16.0,
              right: 16.0,
              bottom: panelBottom,
              child: Offstage(
                offstage: t < 0.01,
                child: IgnorePointer(
                  ignoring: t < 0.3,
                  child: Opacity(
                    opacity: panelFade,
                    child: Transform.translate(
                      offset: Offset(0, panelSlideY),
                      child: isRecord
                          ? _RecordTranscriptPanel(
                              state: widget.transcriptState,
                              adapter: widget.sttAdapter,
                              errorMessage: _recordTranscriptionError,
                            )
                          : _ConversationChatPanel(
                              session: widget.conversationSession,
                              onFinish: widget.onFinishConversation,
                              onRetry: _retryConversationFromBubble,
                            ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Group: Orb + Record/Conversation Switch ────────────────────
            Positioned(
              top: targetY,
              left: 0,
              right: 0,
              child: Transform.translate(
                offset: Offset(0, currentTranslateY),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Hand-painted ink orb with continuous idle/listening animation
                    Transform.scale(
                      scale: orbScale,
                      child: const SizedBox(
                        height: 140,
                        child: Center(
                          child: PainterlyOrb(
                            size: 130,
                            animating: true,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Sub-switch: Record | Conversation
                    _SegmentedSwitch<_VoiceMode>(
                      enabled: togglesEnabled,
                      value: widget.voiceMode,
                      options: const <_VoiceMode>[
                        _VoiceMode.record,
                        _VoiceMode.conversation,
                      ],
                      labelOf: (m) =>
                          m == _VoiceMode.record ? 'Record' : 'Conversation',
                      onChanged: widget.onVoiceModeChanged,
                    ),
                  ],
                ),
              ),
            ),

            // ── Primary Button Pinned at Bottom ─────────────────────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12.0, top: 4.0),
                  child: Center(
                    child: Material(
                      color: isConnected
                          ? cs.primaryContainer
                          : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap:
                            !isRecord &&
                                !widget.conversationVoiceSession.value &&
                                widget.aiRequestInFlight
                            ? null
                            : _handleStartStop,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 12,
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Row(
                              key: ValueKey<String>(buttonLabel),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  buttonIcon,
                                  size: 20,
                                  color: isConnected
                                      ? cs.onPrimaryContainer
                                      : cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  buttonLabel,
                                  style: tt.labelLarge?.copyWith(
                                    color: isConnected
                                        ? cs.onPrimaryContainer
                                        : cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Record Tab: Speech-to-Text Multiline Panel
// ─────────────────────────────────────────────────────────────────────────────

class _RecordTranscriptPanel extends StatefulWidget {
  const _RecordTranscriptPanel({
    required this.state,
    required this.adapter,
    this.errorMessage,
  });

  final TranscriptState state;
  final SttAdapter adapter;
  final String? errorMessage;

  @override
  State<_RecordTranscriptPanel> createState() => _RecordTranscriptPanelState();
}

class _RecordTranscriptPanelState extends State<_RecordTranscriptPanel> {
  late final TextEditingController _textController;
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.state.displayText);
    widget.state.addListener(_onStateChanged);
    widget.adapter.addListener(_onAdapterChanged);
    _scrollController.addListener(_onScroll);
  }

  void _onStateChanged() {
    final String currentDisplay = widget.state.displayText;
    if (_textController.text != currentDisplay) {
      final int oldCursor = _textController.selection.baseOffset;
      _textController.text = currentDisplay;
      if (oldCursor >= 0 && oldCursor <= currentDisplay.length) {
        _textController.selection = TextSelection.collapsed(
          offset: currentDisplay.length,
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_userScrolledUp &&
          _scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    if (mounted) setState(() {});
  }

  void _onAdapterChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final double offsetFromBottom =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    _userScrolledUp = offsetFromBottom > 28;
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    widget.adapter.removeListener(_onAdapterChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                scrollController: _scrollController,
                maxLines: null,
                expands: true,
                readOnly: true,
                showCursor: false,
                enableInteractiveSelection: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: tt.bodyMedium?.copyWith(
                  color: cs.onSurface,
                  height: 1.5,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText:
                      'Recognized speech will appear here live as you speak…',
                  hintStyle: tt.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                    height: 1.5,
                  ),
                  isCollapsed: true,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Draft transcript — not saved',
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    switch (widget.adapter.status) {
                      SttStatus.listening => 'Listening',
                      SttStatus.starting => 'Starting…',
                      SttStatus.error => 'Recognition error',
                      SttStatus.stopped => 'Stopped',
                      SttStatus.paused => 'Paused',
                      SttStatus.idle => 'Ready',
                    },
                    style: tt.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.errorMessage != null ||
                widget.adapter.lastError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  widget.errorMessage ?? widget.adapter.lastError,
                  style: tt.labelSmall?.copyWith(color: cs.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.categories});

  final List<String> categories;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  final TextEditingController _newCategoryController = TextEditingController();
  String? _selectedCategory;

  @override
  void dispose() {
    _newCategoryController.dispose();
    super.dispose();
  }

  void _save() {
    final String category = _newCategoryController.text.trim().isNotEmpty
        ? _newCategoryController.text.trim()
        : (_selectedCategory ?? '').trim();
    if (category.isEmpty) return;
    debugPrint(
      '[note-category] event=category_confirmed new_category=${!widget.categories.any((item) => item.toLowerCase() == category.toLowerCase())}',
    );
    Navigator.of(context).pop(category);
  }

  @override
  Widget build(BuildContext context) {
    final String newCategory = _newCategoryController.text.trim();
    final bool canSave = newCategory.isNotEmpty || _selectedCategory != null;
    return AlertDialog(
      title: const Text('Choose a category'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.categories.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedCategory,
              decoration: const InputDecoration(labelText: 'Existing category'),
              items: widget.categories
                  .map(
                    (category) => DropdownMenuItem(
                      value: category,
                      child: Text(category),
                    ),
                  )
                  .toList(),
              onChanged: (category) =>
                  setState(() => _selectedCategory = category),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const Key('new-category'),
            controller: _newCategoryController,
            decoration: const InputDecoration(
              labelText: 'Or enter a new category',
            ),
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversation Tab: Scrollable WhatsApp-Style Dialogue Panel
// ─────────────────────────────────────────────────────────────────────────────

class _ConversationChatPanel extends StatefulWidget {
  const _ConversationChatPanel({
    required this.session,
    required this.onFinish,
    required this.onRetry,
  });

  final ConversationSession session;
  final Future<void> Function() onFinish;
  final Future<void> Function(String userMessageId) onRetry;

  @override
  State<_ConversationChatPanel> createState() => _ConversationChatPanelState();
}

class _ConversationChatPanelState extends State<_ConversationChatPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    _scrollController.addListener(_onScroll);
  }

  void _onSessionChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_userScrolledUp &&
          _scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final double offsetFromBottom =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    _userScrolledUp = offsetFromBottom > 28;
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final List<ConversationMessage> messages = widget.session.messages;

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 38,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Spoken conversation',
                          style: tt.titleSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Your speech and the AI response text will appear here.',
                          textAlign: TextAlign.center,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final ConversationMessage msg = messages[index];
                    final bool isUser = msg.speaker == ConversationSpeaker.user;

                    return _ChatBubble(
                      message: msg,
                      isUser: isUser,
                      onRetry: widget.onRetry,
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        if (widget.session.status == ConversationStatus.error &&
            widget.session.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.session.error,
                style: tt.bodySmall?.copyWith(color: cs.error),
              ),
            ),
          ),
        if (messages.any((message) => !message.isPartial))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: widget.onFinish,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Finish conversation'),
            ),
          ),
      ],
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.message,
    required this.isUser,
    required this.onRetry,
  });

  final ConversationMessage message;
  final bool isUser;
  final Future<void> Function(String userMessageId) onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isUser ? 48 : 4,
          right: isUser ? 4 : 48,
          bottom: 8,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? cs.primaryContainer
              : message.isError
              ? cs.errorContainer
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.isPending ? '...' : message.text,
              style: tt.bodyMedium?.copyWith(
                color: isUser
                    ? cs.onPrimaryContainer
                    : message.isError
                    ? cs.onErrorContainer
                    : cs.onSurface,
                fontStyle: message.isPartial
                    ? FontStyle.italic
                    : FontStyle.normal,
                height: 1.4,
              ),
            ),
            if (message.isError)
              TextButton(
                onPressed: message.replyToMessageId == null
                    ? null
                    : () => onRetry(message.replyToMessageId!),
                style: TextButton.styleFrom(
                  foregroundColor: cs.onErrorContainer,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Type Tab
// ─────────────────────────────────────────────────────────────────────────────

class _TypeTabContent extends StatelessWidget {
  const _TypeTabContent({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSave,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Material(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: false,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  cursorColor: cs.primary,
                  style: tt.bodyLarge?.copyWith(
                    color: cs.onSurface,
                    height: 1.55,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Start typing your note…',
                    hintStyle: tt.bodyLarge?.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.55),
                      height: 1.55,
                    ),
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              top: 10,
              bottom: BottomPadding.of(context) + 16,
            ),
            child: Row(
              children: [
                Text(
                  'Draft — not saved',
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => onSave(),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Finish note'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Components
// ─────────────────────────────────────────────────────────────────────────────

/// Rounded pill segmented switch reused for Voice/Type and Record/Conversation.
class _SegmentedSwitch<T> extends StatelessWidget {
  const _SegmentedSwitch({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.enabled = true,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1.0 : 0.55,
      child: Container(
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 32),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: options.map((T opt) {
            final bool selected = opt == value;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled
                    ? () {
                        if (!selected) {
                          HapticsHelper.selection();
                          onChanged(opt);
                        }
                      }
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: selected
                        ? cs.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labelOf(opt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelLarge?.copyWith(
                      color: selected
                          ? cs.onSecondaryContainer
                          : cs.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
