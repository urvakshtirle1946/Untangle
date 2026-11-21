import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:bunpod/features/notes/models/note.dart';

// ---------------------------------------------------------------------------
// [UNIT] Category-color helpers in Note
//
// Verifies:
//   1. normalizeCategory: trim + lowercase behavior.
//   2. seedForCategory: known categories map to their assigned palette colors;
//      case variants resolve identically.
//   3. seedForCategory: null/empty/whitespace-only returns neutralSeed.
//   4. seedForCategory: unknown category produces a stable deterministic color.
//   5. seedForNote: categorized note picks category seed; uncategorized picks
//      neutralSeed.
//   6. extractCategories: deduplicates case-insensitively, preserving first-seen
//      casing.
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // 1. normalizeCategory
  // -------------------------------------------------------------------------
  group('Note.normalizeCategory', () {
    test('lowercases and trims input', () {
      expect(Note.normalizeCategory('  Work  '), 'work');
      expect(Note.normalizeCategory('IDEAS'), 'ideas');
      expect(Note.normalizeCategory(' Tasks '), 'tasks');
      expect(Note.normalizeCategory('Personal'), 'personal');
    });

    test('returns empty string for null', () {
      expect(Note.normalizeCategory(null), '');
    });

    test('returns empty string for whitespace-only', () {
      expect(Note.normalizeCategory('   '), '');
    });
  });

  // -------------------------------------------------------------------------
  // 2. seedForCategory — known categories and case normalization
  // -------------------------------------------------------------------------
  group('Note.seedForCategory — known categories', () {
    test('Work (exact) maps to Deep Teal', () {
      expect(Note.seedForCategory('Work'), Note.palette[1]); // 1 = Deep Teal
    });

    test('"work" and "Work" produce the same seed', () {
      expect(Note.seedForCategory('work'), Note.seedForCategory('Work'));
    });

    test('"WORK", " Work ", and "work" all match', () {
      final Color seed = Note.seedForCategory('work');
      expect(Note.seedForCategory('WORK'), seed);
      expect(Note.seedForCategory(' Work '), seed);
    });

    test('Ideas maps to Indigo (palette[3])', () {
      expect(Note.seedForCategory('Ideas'), Note.palette[3]);
      expect(Note.seedForCategory('ideas'), Note.palette[3]);
      expect(Note.seedForCategory(' IDEAS '), Note.palette[3]);
    });

    test('Personal maps to Crimson (palette[0])', () {
      expect(Note.seedForCategory('Personal'), Note.palette[0]);
      expect(Note.seedForCategory('personal'), Note.palette[0]);
    });

    test('Tasks maps to Terracotta (palette[5])', () {
      expect(Note.seedForCategory('Tasks'), Note.palette[5]);
      expect(Note.seedForCategory('tasks'), Note.palette[5]);
      expect(Note.seedForCategory('TASKS'), Note.palette[5]);
    });
  });

  // -------------------------------------------------------------------------
  // 3. seedForCategory — null / empty → neutralSeed
  // -------------------------------------------------------------------------
  group('Note.seedForCategory — null / empty inputs', () {
    test('null returns neutralSeed', () {
      expect(Note.seedForCategory(null), Note.neutralSeed);
    });

    test('empty string returns neutralSeed', () {
      expect(Note.seedForCategory(''), Note.neutralSeed);
    });

    test('whitespace-only returns neutralSeed', () {
      expect(Note.seedForCategory('   '), Note.neutralSeed);
    });
  });

  // -------------------------------------------------------------------------
  // 4. seedForCategory — unknown / new category determinism
  // -------------------------------------------------------------------------
  group('Note.seedForCategory — unknown categories', () {
    test('same unknown category string always returns the same color', () {
      const String cat = 'Hobbies';
      expect(Note.seedForCategory(cat), Note.seedForCategory(cat));
    });

    test('case variants of unknown category agree', () {
      expect(Note.seedForCategory('Hobbies'), Note.seedForCategory('hobbies'));
      expect(Note.seedForCategory(' HOBBIES '), Note.seedForCategory('hobbies'));
    });

    test('unknown category result is always a palette member', () {
      expect(Note.palette, contains(Note.seedForCategory('Hobbies')));
      expect(Note.palette, contains(Note.seedForCategory('Finance')));
    });
  });

  // -------------------------------------------------------------------------
  // 5. seedForNote
  // -------------------------------------------------------------------------
  group('Note.seedForNote', () {
    Note makeNote({String? category}) => Note(
          id: 'test-id',
          userId: 'user-1',
          title: 'T',
          preview: 'P',
          createdAt: DateTime(2024),
          category: category,
        );

    test('null note returns neutralSeed', () {
      expect(Note.seedForNote(null), Note.neutralSeed);
    });

    test('uncategorized note returns neutralSeed', () {
      expect(Note.seedForNote(makeNote()), Note.neutralSeed);
    });

    test('categorized note returns same seed as seedForCategory', () {
      final Note n = makeNote(category: 'Work');
      expect(Note.seedForNote(n), Note.seedForCategory('Work'));
    });

    test('categorized note with irregular casing still picks category seed', () {
      final Note n = makeNote(category: ' IDEAS ');
      expect(Note.seedForNote(n), Note.seedForCategory('IDEAS'));
    });
  });

  // -------------------------------------------------------------------------
  // 6. extractCategories — deduplication
  // -------------------------------------------------------------------------
  group('Note.extractCategories', () {
    Note n(String? category) => Note(
          id: category ?? 'none',
          userId: 'u',
          title: 'T',
          preview: 'P',
          createdAt: DateTime(2024),
          category: category,
        );

    test('deduplicates case-insensitively, preserving first-seen casing', () {
      final List<Note> notes = <Note>[
        n('Work'),
        n('work'),
        n('WORK'),
        n('Ideas'),
      ];
      final List<String> cats = Note.extractCategories(notes);
      expect(cats, <String>['Work', 'Ideas']);
    });

    test('ignores null and whitespace-only categories', () {
      final List<Note> notes = <Note>[n(null), n('   '), n('Tasks')];
      expect(Note.extractCategories(notes), <String>['Tasks']);
    });

    test('returns empty list for notes with no categories', () {
      expect(Note.extractCategories(<Note>[n(null), n(null)]), isEmpty);
    });

    test('trims categories before comparing', () {
      final List<Note> notes = <Note>[n('Work'), n(' Work ')];
      expect(Note.extractCategories(notes), <String>['Work']);
    });
  });
}
