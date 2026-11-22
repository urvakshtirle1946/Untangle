import 'dart:async';

import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../services/voice_note_audio.dart';

sealed class LatestNoteState {
  const LatestNoteState({
    List<String>? categories,
    this.selectedCategory,
    List<Note>? notes,
    List<Note>? filteredNotes,
  }) : categories = categories ?? const <String>[],
       notes = notes ?? const <Note>[],
       filteredNotes = filteredNotes ?? const <Note>[];

  final List<String> categories;
  final String? selectedCategory;
  final List<Note> notes;
  final List<Note> filteredNotes;

  Note? get latestNote =>
      this is LatestNoteLoaded ? (this as LatestNoteLoaded).note : null;

  LatestNoteState copyWith({
    List<String>? categories,
    String? selectedCategory,
    bool clearSelectedCategory = false,
    List<Note>? notes,
    List<Note>? filteredNotes,
    Note? note,
  });
}

class LatestNoteInitial extends LatestNoteState {
  const LatestNoteInitial({
    super.categories = const <String>[],
    super.selectedCategory,
    super.notes = const <Note>[],
    super.filteredNotes = const <Note>[],
  });

  @override
  LatestNoteInitial copyWith({
    List<String>? categories,
    String? selectedCategory,
    bool clearSelectedCategory = false,
    List<Note>? notes,
    List<Note>? filteredNotes,
    Note? note,
  }) {
    return LatestNoteInitial(
      categories: categories ?? this.categories,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      notes: notes ?? this.notes,
      filteredNotes: filteredNotes ?? this.filteredNotes,
    );
  }
}

class LatestNoteLoading extends LatestNoteState {
  const LatestNoteLoading({
    super.categories = const <String>[],
    super.selectedCategory,
    super.notes = const <Note>[],
    super.filteredNotes = const <Note>[],
  });

  @override
  LatestNoteLoading copyWith({
    List<String>? categories,
    String? selectedCategory,
    bool clearSelectedCategory = false,
    List<Note>? notes,
    List<Note>? filteredNotes,
    Note? note,
  }) {
    return LatestNoteLoading(
      categories: categories ?? this.categories,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      notes: notes ?? this.notes,
      filteredNotes: filteredNotes ?? this.filteredNotes,
    );
  }
}

class LatestNoteEmpty extends LatestNoteState {
  const LatestNoteEmpty({
    super.categories = const <String>[],
    super.selectedCategory,
    super.notes = const <Note>[],
    super.filteredNotes = const <Note>[],
  });

  @override
  LatestNoteEmpty copyWith({
    List<String>? categories,
    String? selectedCategory,
    bool clearSelectedCategory = false,
    List<Note>? notes,
    List<Note>? filteredNotes,
    Note? note,
  }) {
    return LatestNoteEmpty(
      categories: categories ?? this.categories,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      notes: notes ?? this.notes,
      filteredNotes: filteredNotes ?? this.filteredNotes,
    );
  }
}

class LatestNoteLoaded extends LatestNoteState {
  const LatestNoteLoaded(
    this.note, {
    super.categories = const <String>[],
    super.selectedCategory,
    super.notes = const <Note>[],
    super.filteredNotes = const <Note>[],
  });

  final Note note;

  @override
  LatestNoteLoaded copyWith({
    List<String>? categories,
    String? selectedCategory,
    bool clearSelectedCategory = false,
    List<Note>? notes,
    List<Note>? filteredNotes,
    Note? note,
  }) {
    return LatestNoteLoaded(
      note ?? this.note,
      categories: categories ?? this.categories,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      notes: notes ?? this.notes,
      filteredNotes: filteredNotes ?? this.filteredNotes,
    );
  }
}

class LatestNoteCubit extends Cubit<LatestNoteState> {
  LatestNoteCubit({
    NotesRepository? repository,
    this.summaryClient,
  }) : _repository =
           repository ??
           (locator.isRegistered<NotesRepository>()
               ? locator<NotesRepository>()
               : InMemoryNotesRepository()),
       super(const LatestNoteInitial());

  final NotesRepository _repository;
  final NoteSummaryClient? summaryClient;
  final Set<String> _summaryStartedIds = <String>{};
  final Set<String> _summaryRetryInFlight = <String>{};
  String? _currentUserId;
  int _notesRevision = 0;

  Future<void> load({String? userId, String? category}) async {
    emit(
      LatestNoteLoading(
        categories: state.categories,
        selectedCategory: state.selectedCategory,
        notes: state.notes,
        filteredNotes: state.filteredNotes,
      ),
    );

    String? effectiveUserId = userId;
    if (effectiveUserId == null && locator.isRegistered<UserCubit>()) {
      effectiveUserId = locator<UserCubit>().state?.id;
    }

    if (effectiveUserId == null && SupabaseConfig.isConfigured) {
      try {
        effectiveUserId = sb.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        // Not initialized in test host
      }
    }

    // Account change detection: clear old user state if user changed
    if (_currentUserId != null && _currentUserId != effectiveUserId) {
      _currentUserId = effectiveUserId;
      emit(const LatestNoteInitial());
    }
    _currentUserId = effectiveUserId;

    if (effectiveUserId == null || effectiveUserId.isEmpty) {
      emit(const LatestNoteEmpty());
      return;
    }
    final int notesRevision = _notesRevision;
    final List<Note> fetchedNotes = await LocalNoteAudioStore().attachToNotes(
      await _repository.getNotes(userId: effectiveUserId),
    );
    final List<Note> allNotes = <Note>[];
    for (final Note note in fetchedNotes) {
      if (note.summaryStatus == 'generating' &&
          !_summaryStartedIds.contains(note.id)) {
        // A previous process may have been killed while waiting on the
        // summary request. Make the saved note retryable after the next load.
        final Note interrupted = note.copyWith(summaryStatus: 'failed');
        try {
          await _repository.saveNote(interrupted);
        } catch (_) {
          // Still show Retry in memory if persisting recovery is unavailable.
        }
        allNotes.add(interrupted);
      } else {
        allNotes.add(note);
      }
    }
    // An older refresh can finish after a save and omit the newly saved note.
    if (isClosed ||
        _currentUserId != effectiveUserId ||
        _notesRevision != notesRevision) {
      return;
    }
    final List<String> categories = Note.extractCategories(allNotes);

    // Determine selectedCategory:
    String? sel = category ?? state.selectedCategory;
    if (sel != null &&
        !categories.any((c) => c.toLowerCase() == sel!.toLowerCase())) {
      // If a selected category disappears, reset to All.
      sel = null;
    }

    final List<Note> filtered = (sel == null || sel.toLowerCase() == 'all')
        ? allNotes
        : allNotes
              .where(
                (n) => n.category?.trim().toLowerCase() == sel!.toLowerCase(),
              )
              .toList();

    final Note? latest = allNotes.firstOrNull;

    if (latest != null) {
      emit(
        LatestNoteLoaded(
          latest,
          categories: categories,
          selectedCategory: sel,
          notes: allNotes,
          filteredNotes: filtered,
        ),
      );
    } else {
      emit(
        LatestNoteEmpty(
          categories: categories,
          selectedCategory: sel,
          notes: allNotes,
          filteredNotes: filtered,
        ),
      );
    }
  }

  /// Persists a note before publishing it to Home's current note state.
  Future<void> saveNote(Note note) async {
    final Note? existing = state.notes
        .where((savedNote) => savedNote.id == note.id)
        .firstOrNull;
    final String currentStatus = existing?.summaryStatus ?? note.summaryStatus;
    final bool canGenerate =
        (summaryClient != null || SupabaseConfig.isConfigured) &&
        currentStatus == 'not_started' &&
        !_summaryStartedIds.contains(note.id);
    if (canGenerate) _summaryStartedIds.add(note.id);
    final Note saved = note.copyWith(
      summaryStatus: canGenerate
          ? 'generating'
          : (currentStatus == 'not_started' ? 'failed' : currentStatus),
    );
    try {
      await _repository.saveNote(saved);
    } catch (_) {
      if (canGenerate) _summaryStartedIds.remove(note.id);
      rethrow;
    }
    setNote(saved);
    if (canGenerate) unawaited(_generateSummary(saved));
  }

  Future<void> updateNote(Note note) async {
    await _repository.saveNote(note);
    setNote(note);
  }

  Future<void> retrySummary(Note note) async {
    if (!_summaryRetryInFlight.add(note.id)) return;
    try {
      final Note generating = note.copyWith(summaryStatus: 'generating');
      await updateNote(generating);
      await _generateSummary(generating);
    } finally {
      _summaryRetryInFlight.remove(note.id);
    }
  }

  Future<void> _generateSummary(Note note) async {
    try {
      final NoteSummaryClient client =
          summaryClient ?? SupabaseNoteSummaryClient();
      final NoteSummary summary = await client.summarize(note.bodyText);
      await updateNote(
        note.copyWith(
          title: summary.title,
          summaryTitle: summary.title,
          summarySections: summary.sections,
          summaryStatus: 'ready',
        ),
      );
    } catch (_) {
      try {
        await updateNote(note.copyWith(summaryStatus: 'failed'));
      } catch (_) {
        // Keep the already-saved note even if status update is unavailable.
      }
    }
  }

  void selectCategory(String? category) {
    final String? normalized =
        (category == null ||
            category.trim().isEmpty ||
            category.trim().toLowerCase() == 'all')
        ? null
        : category.trim();

    String? target;
    if (normalized != null) {
      target = state.categories.cast<String?>().firstWhere(
        (c) => c?.toLowerCase() == normalized.toLowerCase(),
        orElse: () => null,
      );
      // If selected category disappears or doesn't exist, target is null (resets to All).
    }

    final List<Note> filtered = target == null
        ? state.notes
        : state.notes
              .where(
                (n) =>
                    n.category?.trim().toLowerCase() == target!.toLowerCase(),
              )
              .toList();

    if (state is LatestNoteLoaded) {
      emit(
        LatestNoteLoaded(
          (state as LatestNoteLoaded).note,
          categories: state.categories,
          selectedCategory: target,
          notes: state.notes,
          filteredNotes: filtered,
        ),
      );
    } else {
      emit(
        LatestNoteEmpty(
          categories: state.categories,
          selectedCategory: target,
          notes: state.notes,
          filteredNotes: filtered,
        ),
      );
    }
  }

  void setNote(Note? note) {
    _notesRevision++;
    if (note != null) {
      final List<Note> notes = [
        ...state.notes.where((n) => n.id != note.id),
        note,
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final List<String> categories = Note.extractCategories(notes);
      final List<Note> filtered = state.selectedCategory == null
          ? notes
          : notes
                .where(
                  (n) =>
                      n.category?.trim().toLowerCase() ==
                      state.selectedCategory!.toLowerCase(),
                )
                .toList();

      emit(
        LatestNoteLoaded(
          notes.first,
          categories: categories,
          selectedCategory: state.selectedCategory,
          notes: notes,
          filteredNotes: filtered,
        ),
      );
    } else {
      emit(
        LatestNoteEmpty(
          categories: state.categories,
          selectedCategory: state.selectedCategory,
          notes: state.notes,
          filteredNotes: state.filteredNotes,
        ),
      );
    }
  }

  void onAccountSwitched({String? newUserId}) {
    _currentUserId = newUserId;
    emit(const LatestNoteInitial());
  }

  void clear() {
    _currentUserId = null;
    emit(const LatestNoteInitial());
  }
}
