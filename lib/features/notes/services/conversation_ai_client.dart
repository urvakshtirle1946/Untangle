import 'dart:async';
import 'dart:math' as math;

import 'package:bunpod/features/notes/models/voice_note_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

abstract interface class ConversationAiClient {
  Future<String> reply(List<ConversationMessage> history);
}

typedef ConversationAiDiagnostic = void Function(
  String event,
  int elapsedMilliseconds,
);

/// Calls the authenticated Supabase Edge Function. Provider credentials and
/// model selection remain on the server.
class SupabaseConversationAiClient implements ConversationAiClient {
  SupabaseConversationAiClient({sb.SupabaseClient? client})
    : _client = client ?? sb.Supabase.instance.client;

  final sb.SupabaseClient _client;

  @override
  Future<String> reply(List<ConversationMessage> history) => replyWithRequestId(
    history,
    requestId: _newRequestId(),
    sessionId: 'unknown',
    listenGeneration: 0,
    onDiagnostic: (String _, int _) {},
  );

  Future<String> replyWithRequestId(
    List<ConversationMessage> history, {
    required String requestId,
    required String sessionId,
    required int listenGeneration,
    required ConversationAiDiagnostic onDiagnostic,
  }) async {
    final Stopwatch requestTimer = Stopwatch()..start();
    onDiagnostic('event=client_request_start', 0);
    final String? token = _client.auth.currentSession?.accessToken;
    if (token == null) {
      onDiagnostic(
        'event=client_request_exception code=missing_session',
        requestTimer.elapsedMilliseconds,
      );
      throw const ConversationAiException(
        'Sign in before starting an AI conversation.',
        code: 'missing_session',
        statusCode: 401,
      );
    }

    final List<Map<String, String>> messages = history
        .where(
          (message) =>
              !message.isPartial && !message.isPending && !message.isError,
        )
        .toList()
        .reversed
        .take(12)
        .toList()
        .reversed
        .map(
          (message) => <String, String>{
            'role': message.speaker == ConversationSpeaker.user
                ? 'user'
                : 'assistant',
            'content': message.text,
          },
        )
        .toList(growable: false);

    try {
      final sb.FunctionResponse response = await _client.functions
          .invoke(
            'nvidia-chat',
            body: <String, Object>{'messages': messages},
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'x-request-id': requestId,
              'x-conv-session-id': sessionId,
              'x-listen-generation': '$listenGeneration',
            },
          )
          .timeout(const Duration(seconds: 30));
      final Object? data = response.data;
      final Object? returnedRequestId = data is Map ? data['request_id'] : null;
      onDiagnostic(
        'event=client_response_received status=${response.status} returned_request_id_match=${returnedRequestId == requestId}',
        requestTimer.elapsedMilliseconds,
      );
      if (data is Map && data['reply'] is String) {
        final String reply = (data['reply'] as String).trim();
        if (reply.isNotEmpty) return reply;
      }
      throw const ConversationAiException(
        'The AI service returned an empty or invalid response.',
        code: 'invalid_response',
        statusCode: 502,
      );
    } on ConversationAiException {
      rethrow;
    } on sb.FunctionException catch (error) {
      final Object? details = error.details;
      final Object? returnedRequestId = details is Map
          ? details['request_id']
          : null;
      onDiagnostic(
        'event=client_request_exception status=${error.status} returned_request_id_match=${returnedRequestId == requestId}',
        requestTimer.elapsedMilliseconds,
      );
      throw _readFunctionError(error);
    } on Exception catch (error) {
      if (error is TimeoutException) {
        onDiagnostic(
          'event=client_request_exception code=client_timeout',
          requestTimer.elapsedMilliseconds,
        );
        throw const ConversationAiException(
          'The AI request timed out. Please try again.',
          code: 'client_timeout',
          statusCode: 408,
        );
      }
      onDiagnostic(
        'event=client_request_exception code=transport type=${error.runtimeType}',
        requestTimer.elapsedMilliseconds,
      );
      throw const ConversationAiException(
        'Could not reach the AI service. Check your connection and try again.',
        code: 'transport',
      );
    }
  }

  String _newRequestId() {
    final math.Random random = math.Random.secure();
    return 'client-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${random.nextInt(1 << 32).toRadixString(16)}';
  }

  ConversationAiException _readFunctionError(sb.FunctionException error) {
    final Object? details = error.details;
    if (details is Map && details['error'] is String) {
      return ConversationAiException(
        details['error'] as String,
        code: 'edge_function',
        statusCode: error.status,
      );
    }
    if (error.status == 401) {
      return ConversationAiException(
        'Sign in again to use AI conversation.',
        code: 'unauthorized',
        statusCode: error.status,
      );
    }
    if (error.status == 429) {
      return ConversationAiException(
        'Conversation request limit reached. Please wait and try again.',
        code: 'rate_limited',
        statusCode: error.status,
      );
    }
    return ConversationAiException(
      'The AI service is unavailable. Please try again later.',
      code: 'edge_function',
      statusCode: error.status,
    );
  }
}

class ConversationAiException implements Exception {
  const ConversationAiException(
    this.message, {
    this.code = 'unknown',
    this.statusCode,
  });

  final String message;
  final String code;
  final int? statusCode;

  @override
  String toString() => message;
}
