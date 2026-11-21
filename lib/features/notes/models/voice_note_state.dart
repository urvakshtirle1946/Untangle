import 'package:flutter/foundation.dart';

/// Manages live speech-to-text transcript state for the Record tab.
///
/// Features:
/// - In-place partial recognition updates.
/// - Duplicate phrase prevention on finalized utterances.
/// - Preservation of user edits when paused and when resuming.
/// - Disconnected / service status tracking without fake simulation.
class TranscriptState extends ChangeNotifier {
  TranscriptState({
    this.isConnected = false,
  });

  /// Whether an active speech-to-text service is connected.
  bool isConnected;

  String _finalizedText = '';
  String _partialText = '';
  bool _isRecording = false;
  bool _isPaused = false;

  String get finalizedText => _finalizedText;
  String get partialText => _partialText;
  bool get isRecording => _isRecording;
  bool get isPaused => _isPaused;

  void setConnected(bool connected) {
    if (isConnected == connected) return;
    isConnected = connected;
    notifyListeners();
  }

  /// Full text to display in the live transcript box.
  String get displayText {
    final String fin = _finalizedText;
    final String part = _partialText;
    if (fin.isEmpty) return part;
    if (part.isEmpty) return fin;
    return '$fin${_separator(fin, part)}$part';
  }

  String _separator(String left, String right) =>
      (left.isNotEmpty && RegExp(r'\s').hasMatch(left[left.length - 1])) ||
          (right.isNotEmpty && RegExp(r'\s').hasMatch(right[0]))
      ? ''
      : ' ';

  /// Updates live partial recognition in place.
  void updatePartial(String text) {
    _partialText = text;
    notifyListeners();
  }

  /// Appends a finalized utterance once, deduplicating identical trailing phrases.
  void finalizeUtterance(String utterance) {
    if (utterance.isEmpty) {
      _partialText = '';
      notifyListeners();
      return;
    }

    // Check if the finalized text already ends with this exact utterance to avoid duplicates
    final String current = _finalizedText;
    if (current.isEmpty) {
      _finalizedText = utterance;
    } else {
      final String lowerCurrent = current.trimRight().toLowerCase();
      final String lowerUtterance = utterance.trim().toLowerCase();
      if (!lowerCurrent.endsWith(lowerUtterance)) {
        _finalizedText = '$current${_separator(current, utterance)}$utterance';
      }
    }

    _partialText = '';
    notifyListeners();
  }

  /// Appends a distinct recognizer segment, even when it repeats the previous
  /// segment verbatim. Streaming Record sessions may legitimately repeat a
  /// phrase after an endpoint.
  void appendFinalSegment(String utterance) {
    if (utterance.isEmpty) {
      _partialText = '';
      notifyListeners();
      return;
    }
    final String current = _finalizedText;
    _finalizedText = current.isEmpty
        ? utterance
        : '$current${_separator(current, utterance)}$utterance';
    _partialText = '';
    notifyListeners();
  }

  /// Records manual edits typed by the user while paused or idle.
  void updateManualEdits(String editedText) {
    _finalizedText = editedText;
    _partialText = '';
    notifyListeners();
  }

  void startRecording() {
    if (!isConnected) return;
    _isRecording = true;
    _isPaused = false;
    notifyListeners();
  }

  void pauseRecording() {
    if (!_isRecording) return;
    _isPaused = true;
    notifyListeners();
  }

  void resumeRecording() {
    if (!_isRecording || !_isPaused) return;
    _isPaused = false;
    notifyListeners();
  }

  void stopRecording() {
    _isRecording = false;
    _isPaused = false;
    _partialText = '';
    notifyListeners();
  }

  void clear() {
    _finalizedText = '';
    _partialText = '';
    _isRecording = false;
    _isPaused = false;
    notifyListeners();
  }
}

/// Speaker in the voice conversation chat.
enum ConversationSpeaker {
  user,
  ai,
}

/// Status of the spoken dialogue in the Conversation tab.
enum ConversationStatus {
  idle,
  listening,
  thinking,
  finalizing,
  speaking,
  disconnected,
  error,
}

/// Single utterance or reply in the Conversation tab.
class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.speaker,
    required this.text,
    this.isPartial = false,
    this.isPending = false,
    this.isError = false,
    this.replyToMessageId,
    required this.timestamp,
  });

  final String id;
  final ConversationSpeaker speaker;
  final String text;
  final bool isPartial;
  final bool isPending;
  final bool isError;
  final String? replyToMessageId;
  final DateTime timestamp;

  ConversationMessage copyWith({
    String? text,
    bool? isPartial,
    bool? isPending,
    bool? isError,
  }) {
    return ConversationMessage(
      id: id,
      speaker: speaker,
      text: text ?? this.text,
      isPartial: isPartial ?? this.isPartial,
      isPending: isPending ?? this.isPending,
      isError: isError ?? this.isError,
      replyToMessageId: replyToMessageId,
      timestamp: timestamp,
    );
  }
}

/// Manages readable voice conversation messages and live status.
class ConversationSession extends ChangeNotifier {
  ConversationSession({
    this.isConnected = false,
  }) : _status = isConnected
           ? ConversationStatus.idle
           : ConversationStatus.disconnected;

  final bool isConnected;
  ConversationStatus _status;
  String _error = '';
  final List<ConversationMessage> _messages = <ConversationMessage>[];
  static int _messageSequence = 0;

  static String _nextMessageId() => (++_messageSequence).toString();

  ConversationStatus get status => _status;
  String get error => _error;
  List<ConversationMessage> get messages => List.unmodifiable(_messages);

  /// Updates or creates the current user partial recognition bubble on the right.
  void updateUserPartial(String text) {
    final String trimmed = text.trim();
    if (_messages.isNotEmpty &&
        _messages.last.speaker == ConversationSpeaker.user &&
        _messages.last.isPartial) {
      if (trimmed.isEmpty) {
        _messages.removeLast();
      } else {
        _messages[_messages.length - 1] = _messages.last.copyWith(
          text: trimmed,
        );
      }
    } else if (trimmed.isNotEmpty) {
      _messages.add(
        ConversationMessage(
          id: _nextMessageId(),
          speaker: ConversationSpeaker.user,
          text: trimmed,
          isPartial: true,
          timestamp: DateTime.now(),
        ),
      );
    }
    notifyListeners();
  }

  /// Finalizes the user's spoken utterance.
  void finalizeUserUtterance(String text) {
    final String trimmed = text.trim();
    if (_messages.isNotEmpty &&
        _messages.last.speaker == ConversationSpeaker.user &&
        !_messages.last.isPartial &&
        _messages.last.text == trimmed) {
      return;
    }
    if (_messages.isNotEmpty &&
        _messages.last.speaker == ConversationSpeaker.user &&
        _messages.last.isPartial) {
      if (trimmed.isEmpty) {
        _messages.removeLast();
      } else {
        _messages[_messages.length - 1] = _messages.last.copyWith(
          text: trimmed,
          isPartial: false,
        );
      }
    } else if (trimmed.isNotEmpty) {
      _messages.add(
        ConversationMessage(
          id: _nextMessageId(),
          speaker: ConversationSpeaker.user,
          text: trimmed,
          isPartial: false,
          timestamp: DateTime.now(),
        ),
      );
    }
    notifyListeners();
  }

  /// Adds an AI response bubble on the left (text matches voice playback).
  void addAiResponse(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _messages.add(
      ConversationMessage(
        id: _nextMessageId(),
        speaker: ConversationSpeaker.ai,
        text: trimmed,
        isPartial: false,
        timestamp: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  String ensurePendingAiReply(String userMessageId) {
    final int existingIndex = _messages.indexWhere(
      (message) =>
          message.speaker == ConversationSpeaker.ai &&
          message.replyToMessageId == userMessageId,
    );
    if (existingIndex >= 0) {
      final ConversationMessage old = _messages[existingIndex];
      _messages[existingIndex] = old.copyWith(
        text: '...',
        isPending: true,
        isError: false,
      );
      notifyListeners();
      return old.id;
    }
    final String id = _nextMessageId();
    _messages.add(
      ConversationMessage(
        id: id,
        speaker: ConversationSpeaker.ai,
        text: '...',
        isPending: true,
        replyToMessageId: userMessageId,
        timestamp: DateTime.now(),
      ),
    );
    notifyListeners();
    return id;
  }

  void resolveAiReply(String id, String text) {
    final int index = _messages.indexWhere((message) => message.id == id);
    if (index < 0) return;
    _messages[index] = _messages[index].copyWith(
      text: text.trim(),
      isPending: false,
      isError: false,
    );
    notifyListeners();
  }

  void failAiReply(String id, String message) {
    final int index = _messages.indexWhere((message) => message.id == id);
    if (index < 0) return;
    _messages[index] = _messages[index].copyWith(
      text: message,
      isPending: false,
      isError: true,
    );
    notifyListeners();
  }

  void removePendingAiReplies() {
    final int before = _messages.length;
    _messages.removeWhere((message) => message.isPending);
    if (_messages.length != before) notifyListeners();
  }

  void setStatus(ConversationStatus newStatus) {
    if (newStatus != ConversationStatus.error) _error = '';
    _status = newStatus;
    notifyListeners();
  }

  void setError(String message) {
    _error = message;
    _status = ConversationStatus.error;
    notifyListeners();
  }

  void clear() {
    _messages.clear();
    _status = isConnected
        ? ConversationStatus.idle
        : ConversationStatus.disconnected;
    _error = '';
    notifyListeners();
  }
}
