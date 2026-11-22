import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../services/voice_note_audio.dart';

class NoteDetailPage extends StatefulWidget {
  const NoteDetailPage({super.key, required this.note});

  final Note note;

  static void open(BuildContext context, Note note) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => NoteDetailPage(note: note)),
    );
  }

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  late final LatestNoteCubit _cubit;
  late final bool _ownsCubit;
  int _tabIndex = 0;
  bool _selecting = false;
  final Set<int> _selected = <int>{};

  Note get _currentNote =>
      _cubit.state.notes
          .where((note) => note.id == widget.note.id)
          .firstOrNull ??
      widget.note;

  @override
  void initState() {
    super.initState();
    if (locator.isRegistered<LatestNoteCubit>()) {
      _cubit = locator<LatestNoteCubit>();
      _ownsCubit = false;
    } else {
      _cubit = LatestNoteCubit();
      _ownsCubit = true;
      _cubit.setNote(widget.note);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachLocalAudioReference();
  }

  bool _localAudioAttachStarted = false;

  Future<void> _attachLocalAudioReference() async {
    if (_localAudioAttachStarted) return;
    _localAudioAttachStarted = true;
    final List<Note> attached = await LocalNoteAudioStore().attachToNotes(
      <Note>[widget.note],
    );
    if (!mounted || attached.isEmpty) return;
    final Note note = attached.single;
    if (note.localAudioPaths.isNotEmpty || note.audioRecordingFailed) {
      _cubit.setNote(note);
    }
  }

  @override
  void dispose() {
    if (_ownsCubit) _cubit.close();
    super.dispose();
  }

  List<_TranscriptLine> _transcriptLines(Note note) {
    final List<Map<String, dynamic>>? messages = note.conversationMessages;
    if (messages != null && messages.isNotEmpty) {
      return messages
          .map((message) {
            final String speaker =
                message['speaker']?.toString().toLowerCase() ?? '';
            return _TranscriptLine(
              speaker: speaker == 'ai' || speaker == 'assistant' ? 'AI' : 'You',
              text: message['text']?.toString() ?? '',
            );
          })
          .where((line) => line.text.trim().isNotEmpty)
          .toList();
    }
    final String text = note.transcript ?? note.preview;
    final List<String> segments = text
        .split(RegExp(r'\n+|(?<=[.!?])\s+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return segments
        .map((part) => _TranscriptLine(speaker: 'You', text: part))
        .toList();
  }

  String _shareText(Note note) {
    final String transcript = _transcriptLines(note)
        .map((line) => '${line.speaker}: ${line.text}')
        .join('\n');
    return '${note.summaryTitle ?? note.title}\n\n$transcript';
  }

  Future<void> _toggleFavorite(Note note) async {
    try {
      await _cubit.updateNote(note.copyWith(isFavorite: !note.isFavorite));
    } catch (_) {
      if (mounted) _showMessage('Could not update favorite.');
    }
  }

  Future<void> _editTitle(Note note) async {
    final TextEditingController controller = TextEditingController(
      text: note.summaryTitle ?? note.title,
    );
    final String? title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit title'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 160,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || !mounted) return;
    try {
      await _cubit.updateNote(note.copyWith(title: title, summaryTitle: title));
    } catch (_) {
      if (mounted) _showMessage('Could not update title.');
    }
  }

  Future<void> _copySelected(List<_TranscriptLine> lines) async {
    final String text = _selected
        .map((index) {
          final _TranscriptLine line = lines[index];
          return '${line.speaker}: ${line.text}';
        })
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showMessage('Selected transcript copied.');
  }

  Future<void> _shareSelected(List<_TranscriptLine> lines) async {
    final String text = _selected
        .map((index) {
          final _TranscriptLine line = lines[index];
          return '${line.speaker}: ${line.text}';
        })
        .join('\n');
    await SharePlus.instance.share(
      ShareParams(text: text, title: _currentNote.title),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    return BlocBuilder<LatestNoteCubit, LatestNoteState>(
      bloc: _cubit,
      builder: (context, _) {
        final Note note = _currentNote;
        final List<_TranscriptLine> lines = _transcriptLines(note);
        return Scaffold(
          backgroundColor: cs.surface,
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            title: const SizedBox.shrink(),
            actions: [
              if (note.conversationMessages?.isNotEmpty != true)
                _roundAction(
                  context,
                  icon: note.isFavorite
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  tooltip: note.isFavorite ? 'Remove favorite' : 'Favorite',
                  onPressed: () => _toggleFavorite(note),
                  selected: note.isFavorite,
                ),
              _roundAction(
                context,
                icon: Icons.share_rounded,
                tooltip: 'Share note',
                onPressed: () => SharePlus.instance.share(
                  ShareParams(text: _shareText(note), title: note.title),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: _roundIcon(context, Icons.more_horiz_rounded),
                onSelected: (value) {
                  if (value == 'edit') _editTitle(note);
                  if (value == 'copy') {
                    Clipboard.setData(ClipboardData(text: _shareText(note)));
                    _showMessage('Note copied.');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit title')),
                  PopupMenuItem(value: 'copy', child: Text('Copy note')),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: DefaultTabController(
              length: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.summaryTitle ?? note.title,
                          style: GoogleFonts.unbounded(
                            textStyle: tt.headlineSmall,
                            fontWeight: FontWeight.w800,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _metaChip(
                              context,
                              Icons.schedule_rounded,
                              _dateDuration(note),
                            ),
                            _participantChip(
                              context,
                              note.conversationMessages?.isNotEmpty == true,
                            ),
                            if (note.hasCategory)
                              _metaChip(
                                context,
                                Icons.label_outline_rounded,
                                note.category!,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  TabBar(
                    onTap: (index) => setState(() => _tabIndex = index),
                    indicatorSize: TabBarIndicatorSize.label,
                    tabs: const [
                      Tab(text: 'Summary'),
                      Tab(text: 'Transcript'),
                    ],
                  ),
                  Expanded(
                    child: _tabIndex == 0
                        ? _SummaryView(
                            note: note,
                            onRetry: () async {
                              try {
                                await _cubit.retrySummary(note);
                              } catch (_) {
                                if (mounted) {
                                  _showMessage(
                                    'Summary retry could not be saved.',
                                  );
                                }
                              }
                            },
                          )
                        : _transcriptView(note, lines, cs, tt),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_tabIndex == 0) ...[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _showMessage('Ask AI is coming soon.'),
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('Ask AI · Coming soon'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  _audioAction(context, note),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _transcriptView(
    Note note,
    List<_TranscriptLine> lines,
    ColorScheme cs,
    TextTheme tt,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Row(
            children: [
              Chip(
                label: const Text('Transcript'),
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              if (_selecting && _selected.isNotEmpty)
                IconButton(
                  tooltip: 'Share selected',
                  onPressed: () => _shareSelected(lines),
                  icon: const Icon(Icons.share_rounded),
                ),
              if (_selecting && _selected.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _copySelected(lines),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy selected'),
                ),
              TextButton(
                onPressed: () => setState(() {
                  _selecting = !_selecting;
                  _selected.clear();
                }),
                child: Text(_selecting ? 'Done' : 'Select'),
              ),
            ],
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? Center(
                  child: Text(
                    'No transcript is available.',
                    style: tt.bodyMedium,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 112),
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    final _TranscriptLine line = lines[index];
                    final bool selected = _selected.contains(index);
                    return InkWell(
                      onTap: _selecting
                          ? () => setState(
                              () => selected
                                  ? _selected.remove(index)
                                  : _selected.add(index),
                            )
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selecting)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Checkbox(
                                  value: selected,
                                  onChanged: (_) => setState(
                                    () => selected
                                        ? _selected.remove(index)
                                        : _selected.add(index),
                                  ),
                                ),
                              ),
                            CircleAvatar(
                              radius: 17,
                              backgroundColor: line.speaker == 'AI'
                                  ? cs.tertiaryContainer
                                  : cs.primaryContainer,
                              child: Icon(
                                line.speaker == 'AI'
                                    ? Icons.auto_awesome_rounded
                                    : Icons.person_rounded,
                                size: 17,
                                color: line.speaker == 'AI'
                                    ? cs.onTertiaryContainer
                                    : cs.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line.speaker,
                                    style: tt.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    line.text,
                                    style: tt.bodyLarge?.copyWith(height: 1.45),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _dateDuration(Note note) {
    final DateTime date = note.createdAt;
    final String dateText =
        '${_weekday(date.weekday)}, ${_month(date.month)} ${date.day}  ${_hour(date)}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
    final Duration? duration = note.duration;
    if (duration == null) return '$dateText · Duration unavailable';
    return '$dateText · ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _weekday(int value) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][value - 1];
  String _month(int value) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][value - 1];
  String _hour(DateTime date) =>
      (date.hour % 12 == 0 ? 12 : date.hour % 12).toString();

  Widget _roundAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool selected = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface,
        ),
        icon: Icon(icon),
      ),
    );
  }

  Widget _roundIcon(BuildContext context, IconData icon) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: BoxShape.circle,
    ),
    child: Icon(icon, size: 20),
  );

  Widget _metaChip(BuildContext context, IconData icon, String text) => Chip(
    avatar: Icon(icon, size: 16),
    label: Text(text),
    visualDensity: VisualDensity.compact,
  );

  Widget _participantChip(BuildContext context, bool isConversation) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: cs.primaryContainer,
            child: Icon(
              Icons.person_rounded,
              size: 12,
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 5),
          Text('You', style: Theme.of(context).textTheme.labelMedium),
          if (isConversation) ...[
            const SizedBox(width: 10),
            CircleAvatar(
              radius: 10,
              backgroundColor: cs.tertiaryContainer,
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 12,
                color: cs.onTertiaryContainer,
              ),
            ),
            const SizedBox(width: 5),
            Text('AI', style: Theme.of(context).textTheme.labelMedium),
          ],
        ],
      ),
    );
  }

  Widget _audioAction(BuildContext context, Note note) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool hasAudio = note.hasAudio;
    return Semantics(
      label: 'Play recording',
      button: true,
      child: SizedBox.square(
        dimension: 56,
        child: FloatingActionButton(
          heroTag: 'note-audio-${note.id}',
          tooltip: 'Play recording',
          onPressed: () {
            if (!hasAudio && !note.audioRecordingFailed) return;
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => NoteAudioPage(note: note),
              ),
            );
          },
          backgroundColor: hasAudio ? cs.primary : cs.onSurface.withAlpha(38),
          foregroundColor: hasAudio
              ? cs.onPrimary
              : cs.onSurface.withAlpha(120),
          elevation: 0,
          child: const Icon(Icons.graphic_eq_rounded),
        ),
      ),
    );
  }
}

class _SummaryView extends StatelessWidget {
  const _SummaryView({required this.note, required this.onRetry});
  final Note note;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    if (note.summaryStatus == 'generating' ||
        note.summaryStatus == 'not_started') {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Creating your summary…', style: tt.titleMedium),
          const SizedBox(height: 20),
          for (int i = 0; i < 3; i++) ...[
            Container(
              height: 18,
              width: 130,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 12),
            for (int j = 0; j < 2; j++) ...[
              Container(
                height: 12,
                margin: const EdgeInsets.only(left: 12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 16),
          ],
        ],
      );
    }
    if (note.summaryStatus == 'failed' || note.summarySections == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 38),
              const SizedBox(height: 12),
              Text('Summary unavailable', style: tt.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Your transcript is saved. Try generating the summary again.',
                textAlign: TextAlign.center,
                style: tt.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      children: [
        for (final Map<String, dynamic> section in note.summarySections!) ...[
          Text(
            section['heading'] as String,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          for (final String bullet
              in (section['bullets'] as List).cast<String>())
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Icon(Icons.circle, size: 7, color: cs.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      bullet,
                      style: tt.bodyLarge?.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class _TranscriptLine {
  const _TranscriptLine({required this.speaker, required this.text});
  final String speaker;
  final String text;
}
