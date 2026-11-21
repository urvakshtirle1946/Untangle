import 'package:bunpod/features/notes/models/note.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

abstract class NotesRepository {
  /// Retrieves notes for a specific user, optionally filtered by category.
  /// If [category] is null, empty, or 'all', all notes (including uncategorized notes)
  /// are returned. Uncategorized notes remain visible in All.
  Future<List<Note>> getNotes({required String userId, String? category});

  /// Retrieves distinct categories present in the user's saved notes,
  /// trimmed and deduplicated case-insensitively.
  Future<List<String>> getCategories({required String userId});

  /// Retrieves the single most recently created note for a user.
  Future<Note?> getLatestNote({required String userId});

  /// Saves or updates a note in the repository.
  Future<void> saveNote(Note note);

  /// Clears notes for the given user or all notes.
  Future<void> clear({String? userId});
}

/// Supabase-backed, persistent notes repository. RLS on `public.notes` scopes
/// every request to the authenticated user; no privileged key is used here.
class SupabaseNotesRepository implements NotesRepository {
  SupabaseNotesRepository({sb.SupabaseClient? client})
    : _providedClient = client;

  final sb.SupabaseClient? _providedClient;
  sb.SupabaseClient get _client =>
      _providedClient ?? sb.Supabase.instance.client;

  static const String _columns =
      'id,user_id,title,preview,transcript,conversation_messages,created_at,category,category_source,audio_url,duration_seconds,summary_title,summary_sections,summary_status,is_favorite';

  @visibleForTesting
  static Map<String, dynamic> payloadFor(Note note) => <String, dynamic>{
    'id': note.id,
    'user_id': note.userId,
    'title': note.title,
    'preview': note.preview,
    'transcript': note.transcript,
    // The database column is NOT NULL with a default, but explicit JSON null
    // bypasses that default. Record notes have no messages, so send []; a
    // Conversation's structured message list passes through unchanged.
    'conversation_messages':
        note.conversationMessages ?? <Map<String, dynamic>>[],
    'created_at': note.createdAt.toUtc().toIso8601String(),
    'category': note.category,
    'category_source': note.categorySource?.name,
    'audio_url': note.audioUrl,
    'duration_seconds': note.duration?.inSeconds,
    'summary_title': note.summaryTitle,
    'summary_sections': note.summarySections,
    'summary_status': note.summaryStatus,
    'is_favorite': note.isFavorite,
  };

  Note _noteFromRow(Map<String, dynamic> row) {
    final String? category = row['category'] as String?;
    final String? source = row['category_source'] as String?;
    return Note(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      title: row['title'] as String,
      preview: row['preview'] as String? ?? row['transcript'] as String? ?? '',
      transcript: row['transcript'] as String?,
      conversationMessages: (row['conversation_messages'] as List<dynamic>?)
          ?.map((message) => Map<String, dynamic>.from(message as Map))
          .toList(growable: false),
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      category: category,
      categorySource: source == 'user' || (source == null && category != null)
          ? CategorySource.user
          : source == 'ai'
          ? CategorySource.ai
          : null,
      audioUrl: row['audio_url'] as String?,
      duration: row['duration_seconds'] == null
          ? null
          : Duration(seconds: row['duration_seconds'] as int),
      summaryTitle: row['summary_title'] as String?,
      summarySections: (row['summary_sections'] as List<dynamic>?)
          ?.map((section) => Map<String, dynamic>.from(section as Map))
          .toList(growable: false),
      summaryStatus: row['summary_status'] as String? ?? 'not_started',
      isFavorite: row['is_favorite'] as bool? ?? false,
    );
  }

  @override
  Future<List<Note>> getNotes({
    required String userId,
    String? category,
  }) async {
    dynamic query = _client
        .from('notes')
        .select(_columns)
        .eq('user_id', userId);
    if (category != null &&
        category.trim().isNotEmpty &&
        category.trim().toLowerCase() != 'all') {
      query = query.ilike('category', category.trim());
    }
    final List<dynamic> rows = await query.order(
      'created_at',
      ascending: false,
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(_noteFromRow)
        .toList(growable: false);
  }

  @override
  Future<List<String>> getCategories({required String userId}) async {
    final List<Note> notes = await getNotes(userId: userId);
    return Note.extractCategories(notes);
  }

  @override
  Future<Note?> getLatestNote({required String userId}) async {
    final List<Note> notes = await getNotes(userId: userId);
    return notes.firstOrNull;
  }

  @override
  Future<void> saveNote(Note note) async {
    await _client.from('notes').upsert(payloadFor(note), onConflict: 'id');
  }

  @override
  Future<void> clear({String? userId}) async {
    throw UnsupportedError(
      'Persisted notes cannot be cleared through this repository.',
    );
  }
}

/// In-memory implementation of [NotesRepository].
/// By default, initialized with an empty list to honestly reflect that note
/// capture and backend storage are not yet configured in this project.
class InMemoryNotesRepository implements NotesRepository {
  InMemoryNotesRepository({List<Note>? initialNotes})
    : _notes = List<Note>.from(initialNotes ?? <Note>[]);

  final List<Note> _notes;

  @override
  Future<List<Note>> getNotes({
    required String userId,
    String? category,
  }) async {
    final List<Note> userNotes =
        _notes.where((n) => n.userId == userId).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (category == null ||
        category.trim().isEmpty ||
        category.trim().toLowerCase() == 'all') {
      return userNotes;
    }

    final String target = category.trim().toLowerCase();
    return userNotes.where((n) {
      final String? cat = n.category?.trim().toLowerCase();
      return cat == target;
    }).toList();
  }

  @override
  Future<List<String>> getCategories({required String userId}) async {
    final List<Note> userNotes = await getNotes(userId: userId);
    return Note.extractCategories(userNotes);
  }

  @override
  Future<Note?> getLatestNote({required String userId}) async {
    final List<Note> userNotes = await getNotes(userId: userId);
    return userNotes.firstOrNull;
  }

  @override
  Future<void> saveNote(Note note) async {
    final int index = _notes.indexWhere((n) => n.id == note.id);
    if (index >= 0) {
      _notes[index] = note;
    } else {
      _notes.add(note);
    }
  }

  @override
  Future<void> clear({String? userId}) async {
    if (userId != null) {
      _notes.removeWhere((n) => n.userId == userId);
    } else {
      _notes.clear();
    }
  }
}
