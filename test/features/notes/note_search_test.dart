import 'package:flutter_test/flutter_test.dart';

import 'package:bunpod/features/notes/models/note.dart';
import 'package:bunpod/features/notes/services/notes_repository.dart';

// ---------------------------------------------------------------------------
// [UNIT] NoteSearchPage search logic
//
// The search logic lives inline in _NoteSearchPageState._onChanged.
// We test the underlying filtering contract directly against
// InMemoryNotesRepository so we can verify:
//   1. Empty query returns no results.
//   2. Title match (case-insensitive).
//   3. Transcript/preview match (case-insensitive).
//   4. No match returns empty list.
//   5. Multiple matches are all returned.
//   6. Full saved transcripts are searchable beyond their card preview.
// ---------------------------------------------------------------------------

List<Note> _search(List<Note> notes, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return <Note>[];
  return notes.where((Note n) {
    return n.title.toLowerCase().contains(q) ||
        n.bodyText.toLowerCase().contains(q);
  }).toList();
}

Note _note({
  required String id,
  required String title,
  String preview = '',
  String? transcript,
  String? category,
}) => Note(
  id: id,
  userId: 'u1',
  title: title,
  preview: preview,
  transcript: transcript,
  createdAt: DateTime(2024),
  category: category,
);

void main() {
  final List<Note> corpus = <Note>[
    _note(
      id: '1',
      title: 'Quarterly product roadmap review',
      preview: 'Milestones and sprints discussed.',
      category: 'Work',
    ),
    _note(
      id: '2',
      title: 'Expressive morphing UI patterns',
      preview: 'Spring animations for pill selection.',
      category: 'Ideas',
    ),
    _note(
      id: '3',
      title: 'Weekend trail running gear list',
      preview: 'Hydration vest and offline GPS maps.',
      category: 'Personal',
    ),
    _note(
      id: '4',
      title: 'Clean up project dependencies',
      preview: 'Audit unused packages in pubspec.',
      category: 'Tasks',
    ),
    _note(
      id: '5',
      title: 'Uncategorized reflection',
      preview: 'Offline-first state synchronization.',
      transcript: 'Offline-first state synchronization. The later transcript includes a rare phrase.',
    ),
  ];

  // -------------------------------------------------------------------------
  // 1. Empty / whitespace query → no results
  // -------------------------------------------------------------------------
  group('empty query', () {
    test('empty string returns empty list', () {
      expect(_search(corpus, ''), isEmpty);
    });

    test('whitespace-only returns empty list', () {
      expect(_search(corpus, '   '), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 2. Title matching
  // -------------------------------------------------------------------------
  group('title matching', () {
    test('exact substring in title matches', () {
      final List<Note> r = _search(corpus, 'roadmap');
      expect(r.length, 1);
      expect(r.first.id, '1');
    });

    test('case-insensitive title match', () {
      expect(_search(corpus, 'ROADMAP'), _search(corpus, 'roadmap'));
      expect(_search(corpus, 'Roadmap'), _search(corpus, 'roadmap'));
    });

    test('partial title match finds note', () {
      final List<Note> r = _search(corpus, 'trail');
      expect(r.length, 1);
      expect(r.first.id, '3');
    });
  });

  // -------------------------------------------------------------------------
  // 3. Body/preview matching
  // -------------------------------------------------------------------------
  group('preview/body matching', () {
    test('preview substring match', () {
      final List<Note> r = _search(corpus, 'pubspec');
      expect(r.length, 1);
      expect(r.first.id, '4');
    });

    test('case-insensitive preview match', () {
      final List<Note> r = _search(corpus, 'PUBSPEC');
      expect(r.length, 1);
      expect(r.first.id, '4');
    });

    test('preview match on uncategorized note', () {
      final List<Note> r = _search(corpus, 'synchronization');
      expect(r.length, 1);
      expect(r.first.id, '5');
    });

    test('full transcript beyond the preview is searchable', () {
      expect(_search(corpus, 'rare phrase').single.id, '5');
    });
  });

  // -------------------------------------------------------------------------
  // 4. No match
  // -------------------------------------------------------------------------
  group('no match', () {
    test('unrelated query returns empty list', () {
      expect(_search(corpus, 'podcast'), isEmpty);
    });

    test('partial non-matching prefix returns empty list', () {
      expect(_search(corpus, 'xyzzy'), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 5. Multiple matches
  // -------------------------------------------------------------------------
  group('multiple matches', () {
    test('query matching multiple notes returns all', () {
      // 'list' appears in note 3 title ("gear list") and is not in others
      // Use a token present in multiple: 'e' is too broad; use 'offline'
      // which appears in note 3 preview ("offline GPS") and note 5 preview.
      final List<Note> r = _search(corpus, 'offline');
      expect(r.length, 2);
      final Set<String> ids = r.map((n) => n.id).toSet();
      expect(ids, containsAll(<String>['3', '5']));
    });
  });

  // -------------------------------------------------------------------------
  // 6. InMemoryNotesRepository round-trip (ensures search scope is per-user)
  // -------------------------------------------------------------------------
  group('InMemoryNotesRepository — user isolation', () {
    test('getNotes returns only notes for the requested userId', () async {
      final InMemoryNotesRepository repo = InMemoryNotesRepository(
        initialNotes: <Note>[
          _note(id: 'a', title: 'User A note'),
          Note(
            id: 'b',
            userId: 'u2',
            title: 'User B note',
            preview: '',
            createdAt: DateTime(2024),
          ),
        ],
      );

      final List<Note> u1Notes = await repo.getNotes(userId: 'u1');
      expect(u1Notes.length, 1);
      expect(u1Notes.first.id, 'a');

      // Searching u1's corpus against a u2-only term should return nothing.
      final List<Note> result = _search(u1Notes, 'User B');
      expect(result, isEmpty);
    });
  });
}
