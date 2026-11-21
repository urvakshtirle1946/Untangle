import 'package:supabase_flutter/supabase_flutter.dart' as sb;

class NoteSummary {
  const NoteSummary({required this.title, required this.sections});

  final String title;
  final List<Map<String, dynamic>> sections;

  factory NoteSummary.fromJson(Object? value) {
    if (value is! Map ||
        value['title'] is! String ||
        value['sections'] is! List) {
      throw const FormatException('Invalid note summary response.');
    }
    final String title = (value['title'] as String).trim();
    if (title.isEmpty || title.length > 160) {
      throw const FormatException('Invalid note summary title.');
    }
    final List<Map<String, dynamic>> sections = <Map<String, dynamic>>[];
    for (final Object? rawSection in value['sections'] as List) {
      if (rawSection is! Map ||
          rawSection['heading'] is! String ||
          rawSection['bullets'] is! List) {
        throw const FormatException('Invalid note summary section.');
      }
      final String heading = (rawSection['heading'] as String).trim();
      final List<Object?> rawBullets = (rawSection['bullets'] as List)
          .cast<Object?>();
      if (heading.isEmpty ||
          heading.length > 80 ||
          rawBullets.isEmpty ||
          rawBullets.length > 8) {
        throw const FormatException('Invalid note summary section.');
      }
      final List<String> bullets = <String>[];
      for (final Object? bullet in rawBullets) {
        if (bullet is! String || bullet.trim().isEmpty || bullet.length > 500) {
          throw const FormatException('Invalid note summary bullet.');
        }
        bullets.add(bullet.trim());
      }
      sections.add(<String, dynamic>{'heading': heading, 'bullets': bullets});
    }
    if (sections.isEmpty || sections.length > 12) {
      throw const FormatException('Invalid note summary sections.');
    }
    return NoteSummary(title: title, sections: sections);
  }
}

abstract interface class NoteSummaryClient {
  Future<NoteSummary> summarize(String transcript);
}

class SupabaseNoteSummaryClient implements NoteSummaryClient {
  SupabaseNoteSummaryClient({sb.SupabaseClient? client})
    : _client = client ?? sb.Supabase.instance.client;

  final sb.SupabaseClient _client;

  @override
  Future<NoteSummary> summarize(String transcript) async {
    final String? token = _client.auth.currentSession?.accessToken;
    if (token == null) throw StateError('Sign in to generate a note summary.');
    final sb.FunctionResponse response = await _client.functions
        .invoke(
          'nvidia-chat',
          body: <String, Object>{
            'action': 'summarize',
            'transcript': transcript,
          },
          headers: <String, String>{'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 45));
    final Object? data = response.data;
    if (data is! Map || data['summary'] == null) {
      throw const FormatException(
        'The summary service returned an invalid response.',
      );
    }
    return NoteSummary.fromJson(data['summary']);
  }
}
