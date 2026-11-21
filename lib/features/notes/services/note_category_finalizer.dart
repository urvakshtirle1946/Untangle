import 'package:bunpod/features/notes/models/note.dart';

/// Integration contract for assigning an AI category from the complete
/// recording transcript or conversation after Submit/completion.
///
/// Precedence contract:
/// - Explicit user-entered/selected category always wins.
/// - Otherwise, finalization assigns an AI category from the complete
///   transcript/conversation only after Submit/completion.
/// - If no real AI finalization exists yet, this interface serves as the
///   contract without faking classification.
abstract class NoteCategoryFinalizer {
  Future<Note> finalizeCategory({
    required Note note,
    String? transcript,
    List<String>? conversation,
    String? suggestedAiCategory,
  });
}

/// Integration contract implementation.
///
/// Enforces user-category precedence and passes through without faking classification
/// until the recording / AI pipeline is wired up.
class IntegrationNoteCategoryFinalizer implements NoteCategoryFinalizer {
  const IntegrationNoteCategoryFinalizer();

  @override
  Future<Note> finalizeCategory({
    required Note note,
    String? transcript,
    List<String>? conversation,
    String? suggestedAiCategory,
  }) async {
    // Explicit user-entered category always wins.
    if (note.isUserCategory && note.hasCategory) {
      return note;
    }

    // Only assign if a suggested AI category is explicitly supplied upon finalization.
    if (suggestedAiCategory != null && suggestedAiCategory.trim().isNotEmpty) {
      return note.withAiCategory(suggestedAiCategory);
    }

    return note;
  }
}
