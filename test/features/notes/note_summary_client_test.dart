import 'package:bunpod/bunpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSummaryClient implements NoteSummaryClient {
  int calls = 0;
  bool fail = false;

  @override
  Future<NoteSummary> summarize(String transcript) async {
    calls++;
    if (fail) throw StateError('summary unavailable');
    return const NoteSummary(
      title: 'Saved title',
      sections: [
        {
          'heading': 'Today',
          'bullets': ['Keep the original transcript.'],
        },
      ],
    );
  }
}

void main() {
  test('summary response validates and preserves structured sections', () {
    final NoteSummary summary = NoteSummary.fromJson({
      'title': 'Project plan',
      'sections': [
        {
          'heading': 'Goals',
          'bullets': ['Ship the first version.'],
        },
      ],
    });
    expect(summary.title, 'Project plan');
    expect(summary.sections.single['heading'], 'Goals');
    expect(summary.sections.single['bullets'], ['Ship the first version.']);
  });

  test('summary response rejects malformed and empty sections', () {
    expect(
      () => NoteSummary.fromJson({'title': 'Project plan', 'sections': []}),
      throwsFormatException,
    );
    expect(
      () => NoteSummary.fromJson({
        'title': 'Project plan',
        'sections': [
          {
            'heading': 'Goals',
            'bullets': [''],
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test(
    'saving a note requests a summary once and stores structured result',
    () async {
      final InMemoryNotesRepository repository = InMemoryNotesRepository();
      final _FakeSummaryClient client = _FakeSummaryClient();
      final LatestNoteCubit cubit = LatestNoteCubit(
        repository: repository,
        summaryClient: client,
      );
      final Note note = Note(
        id: 'summary-1',
        userId: 'user-1',
        title: 'Original title',
        preview: 'A note transcript.',
        transcript: 'A note transcript.',
        createdAt: DateTime(2026),
      );
      await cubit.saveNote(note);
      await Future<void>.delayed(Duration.zero);
      final Note saved = (await repository.getNotes(userId: 'user-1')).single;
      expect(client.calls, 1);
      expect(saved.summaryStatus, 'ready');
      expect(saved.title, 'Saved title');
      expect(saved.summarySections?.single['heading'], 'Today');
      await cubit.close();
    },
  );

  test('summary failure keeps the saved note and marks retry state', () async {
    final InMemoryNotesRepository repository = InMemoryNotesRepository();
    final _FakeSummaryClient client = _FakeSummaryClient()..fail = true;
    final LatestNoteCubit cubit = LatestNoteCubit(
      repository: repository,
      summaryClient: client,
    );
    final Note note = Note(
      id: 'summary-fail-1',
      userId: 'user-1',
      title: 'Original title',
      preview: 'A note transcript.',
      transcript: 'A note transcript.',
      createdAt: DateTime(2026),
    );
    await cubit.saveNote(note);
    await Future<void>.delayed(Duration.zero);
    final Note saved = (await repository.getNotes(userId: 'user-1')).single;
    expect(client.calls, 1);
    expect(saved.summaryStatus, 'failed');
    expect(saved.transcript, note.transcript);
    await cubit.close();
  });

  test('load recovers an interrupted generating summary into retry state', () async {
    final Note interrupted = Note(
      id: 'summary-interrupted-1',
      userId: 'user-1',
      title: 'Original title',
      preview: 'A note transcript.',
      transcript: 'A note transcript.',
      createdAt: DateTime(2026),
      summaryStatus: 'generating',
    );
    final InMemoryNotesRepository repository = InMemoryNotesRepository(
      initialNotes: <Note>[interrupted],
    );
    final LatestNoteCubit cubit = LatestNoteCubit(repository: repository);
    await cubit.load(userId: 'user-1');
    final Note recovered = (await repository.getNotes(userId: 'user-1')).single;
    expect(recovered.summaryStatus, 'failed');
    expect(cubit.state.notes.single.summaryStatus, 'failed');
    await cubit.close();
  });
}
