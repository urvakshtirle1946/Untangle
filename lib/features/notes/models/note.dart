import 'dart:math';

import 'package:material_ui/material_ui.dart';

enum CategorySource {
  user,
  ai;

  bool get isUser => this == CategorySource.user;
  bool get isAi => this == CategorySource.ai;
}

class Note {
  const Note({
    required this.id,
    required this.userId,
    required this.title,
    required this.preview,
    required this.createdAt,
    this.transcript,
    this.conversationMessages,
    this.audioUrl,
    this.duration,
    this.localAudioPaths = const <String>[],
    this.localAudioFileSizeBytes,
    this.audioRecordingFailed = false,
    this.category,
    this.categorySource,
    this.summaryTitle,
    this.summarySections,
    this.summaryStatus = 'not_started',
    this.isFavorite = false,
  });

  final String id;
  final String userId;
  final String title;
  final String preview;

  /// Full text captured by speech recognition, when this is a transcript note.
  final String? transcript;

  /// Ordered, structured User/AI messages for conversation notes.
  final List<Map<String, dynamic>>? conversationMessages;
  final DateTime createdAt;

  /// Attached audio recording URL or local file path.
  /// If null or empty, the note has no recording.
  final String? audioUrl;

  /// Device-local audio files; kept out of Supabase audio_url.
  final List<String> localAudioPaths;
  final int? localAudioFileSizeBytes;

  /// Local diagnostic state; not written to the cloud notes schema.
  final bool audioRecordingFailed;

  /// Duration of the attached recording, if known.
  final Duration? duration;

  /// Optional category label (e.g. "Ideas", "Tasks", "Work").
  final String? category;

  /// Provenance of the assigned category: explicit [user] choice or [ai] classification.
  final CategorySource? categorySource;

  final String? summaryTitle;
  final List<Map<String, dynamic>>? summarySections;
  final String summaryStatus;
  final bool isFavorite;

  bool get hasAudio =>
      (audioUrl != null && audioUrl!.trim().isNotEmpty) ||
      (!audioRecordingFailed && localAudioPaths.isNotEmpty);

  String get bodyText => transcript ?? preview;

  static String newId() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  bool get hasCategory => category != null && category!.trim().isNotEmpty;

  bool get isUserCategory => categorySource == CategorySource.user;

  bool get isAiCategory => categorySource == CategorySource.ai;

  /// Assigns an explicit user-entered category. Explicit user category always wins.
  Note withUserCategory(String? newCategory) {
    final String? trimmed = newCategory?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return copyWith(clearCategory: true);
    }
    return copyWith(
      category: trimmed,
      categorySource: CategorySource.user,
    );
  }

  /// Assigns an AI category from complete transcript or conversation only if
  /// the user has not explicitly set a category. Explicit user category always wins.
  Note withAiCategory(String? aiCategory) {
    if (isUserCategory && hasCategory) {
      return this; // User-selected category strictly preserved
    }
    final String? trimmed = aiCategory?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return copyWith(clearCategory: true);
    }
    return copyWith(
      category: trimmed,
      categorySource: CategorySource.ai,
    );
  }

  /// Extracts, trims, and deduplicates categories case-insensitively,
  /// preserving the first-seen canonical casing.
  static List<String> extractCategories(Iterable<Note> notes) {
    final List<String> result = <String>[];
    final Set<String> seenLower = <String>{};

    for (final Note note in notes) {
      final String? raw = note.category;
      if (raw == null) continue;
      final String trimmed = raw.trim();
      if (trimmed.isEmpty) continue;

      if (seenLower.add(trimmed.toLowerCase())) {
        result.add(trimmed);
      }
    }
    return result;
  }

  Note copyWith({
    String? id,
    String? userId,
    String? title,
    String? preview,
    String? transcript,
    List<Map<String, dynamic>>? conversationMessages,
    DateTime? createdAt,
    String? audioUrl,
    Duration? duration,
    List<String>? localAudioPaths,
    int? localAudioFileSizeBytes,
    bool? audioRecordingFailed,
    String? category,
    CategorySource? categorySource,
    bool clearCategory = false,
    bool clearAudio = false,
    String? summaryTitle,
    List<Map<String, dynamic>>? summarySections,
    String? summaryStatus,
    bool? isFavorite,
  }) {
    return Note(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      preview: preview ?? this.preview,
      transcript: transcript ?? this.transcript,
      conversationMessages: conversationMessages ?? this.conversationMessages,
      createdAt: createdAt ?? this.createdAt,
      audioUrl: clearAudio ? null : (audioUrl ?? this.audioUrl),
      duration: clearAudio ? null : (duration ?? this.duration),
      localAudioPaths: clearAudio
          ? const <String>[]
          : (localAudioPaths ?? this.localAudioPaths),
      localAudioFileSizeBytes: clearAudio
          ? null
          : (localAudioFileSizeBytes ?? this.localAudioFileSizeBytes),
      audioRecordingFailed: clearAudio
          ? false
          : (audioRecordingFailed ?? this.audioRecordingFailed),
      category: clearCategory ? null : (category ?? this.category),
      categorySource: clearCategory
          ? null
          : (categorySource ?? this.categorySource),
      summaryTitle: summaryTitle ?? this.summaryTitle,
      summarySections: summarySections ?? this.summarySections,
      summaryStatus: summaryStatus ?? this.summaryStatus,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  /// Curated palette of seed colors used by note and content cards.
  static const List<Color> palette = <Color>[
    Color(0xFFB01E28), // 0: Crimson / Burgundy
    Color(0xFF1F7A6B), // 1: Deep Teal
    Color(0xFF294B63), // 2: Slate Blue (neutral fallback)
    Color(0xFF4C6EF5), // 3: Indigo
    Color(0xFF311732), // 4: Deep Violet
    Color(0xFFA1836E), // 5: Terracotta / Sand
    Color(0xFF2F6E8F), // 6: Steel Blue
    Color(0xFF7D6D5E), // 7: Warm Mocha
  ];

  /// Neutral fallback seed used for uncategorized notes and empty states.
  // ignore: prefer_const_constructors — const list indexing is not allowed in
  // a constant expression; static final is the correct alternative.
  static final Color neutralSeed = palette[2]; // Slate Blue

  /// Distinct seed indices for established categories.
  static const Map<String, int> _knownCategoryIndices = <String, int>{
    'work': 1, // Deep Teal
    'ideas': 3, // Indigo
    'personal': 0, // Crimson
    'tasks': 5, // Terracotta
  };

  /// Normalizes a category name by trimming whitespace and converting to lowercase.
  static String normalizeCategory(String? category) {
    return category?.trim().toLowerCase() ?? '';
  }

  /// Shared helper returning a distinct seed color for a category.
  /// Normalizes category name with trim + lowercase so "Work" and "work" match.
  /// Uses distinct seeds for demo categories, and a deterministic hash fallback for new ones.
  /// Uncategorized/null returns [neutralSeed].
  static Color seedForCategory(String? category) {
    final String key = normalizeCategory(category);
    if (key.isEmpty) {
      return neutralSeed;
    }
    final int? knownIndex = _knownCategoryIndices[key];
    if (knownIndex != null) {
      return palette[knownIndex];
    }
    final int hash = key.codeUnits.fold<int>(0, (acc, c) => acc * 31 + c);
    return palette[hash.abs() % palette.length];
  }

  /// Derives the seed color for a note: uses the category seed when categorized
  /// (replacing note-ID seed), or [neutralSeed] when uncategorized.
  static Color seedForNote(Note? note) {
    if (note == null) {
      return neutralSeed;
    }
    if (note.hasCategory) {
      return seedForCategory(note.category);
    }
    return neutralSeed;
  }

  /// Derives the seed color for this note:
  /// Uses category seed when categorized, or [neutralSeed] for uncategorized notes.
  Color get seedColor => seedForNote(this);

  /// Deterministically maps a string ID to a color in [palette] (legacy fallback).
  static Color seedFor(String? id) {
    if (id == null || id.isEmpty) {
      return neutralSeed;
    }
    final int hash = id.codeUnits.fold<int>(0, (acc, c) => acc * 31 + c);
    return palette[hash.abs() % palette.length];
  }

  /// Generates a brightness-aware [ColorScheme] using the same content-variant
  /// logic used by Channel and Episode models.
  ColorScheme scheme(BuildContext context) => schemeFor(context, this);

  /// Generates a brightness-aware [ColorScheme] for a given note (or fallback).
  static ColorScheme schemeFor(BuildContext context, [Note? note]) {
    final Color seed = seedForNote(note);
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Theme.of(context).brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.content,
    );
  }

  /// Generates a brightness-aware [ColorScheme] for a category name.
  static ColorScheme schemeForCategory(BuildContext context, String? category) {
    final Color seed = seedForCategory(category);
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Theme.of(context).brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.content,
    );
  }
}
