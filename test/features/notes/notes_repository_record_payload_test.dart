import 'package:bunpod/features/notes/models/note.dart';
import 'package:bunpod/features/notes/services/notes_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Record note payload sends empty conversation_messages array', () {
    final Note recordNote = Note(
      id: '00000000-0000-4000-8000-000000000001',
      userId: '00000000-0000-4000-8000-000000000002',
      title: 'Voice note',
      preview: '',
      transcript: null,
      createdAt: DateTime.utc(2026),
    );

    final Map<String, dynamic> payload = SupabaseNotesRepository.payloadFor(
      recordNote,
    );

    expect(payload['preview'], '');
    expect(payload['transcript'], isNull);
    expect(payload['conversation_messages'], isA<List<dynamic>>());
    expect(payload['conversation_messages'], isEmpty);
  });
}
