import 'package:bunpod/bunpod.dart';
import 'package:expressive_shapes/expressive_shapes.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon;
import 'package:material_wavy_progress_indicator/material_wavy_progress_indicator.dart';

class LatestNoteCard extends StatelessWidget {
  const LatestNoteCard({super.key, this.note});

  final Note? note;

  @override
  Widget build(BuildContext context) {
    if (note != null) {
      return _NoteCardContent(note: note!);
    }

    final LatestNoteCubit noteCubit = locator.isRegistered<LatestNoteCubit>()
        ? locator<LatestNoteCubit>()
        : LatestNoteCubit();

    return BlocBuilder<LatestNoteCubit, LatestNoteState>(
      bloc: noteCubit,
      builder: (context, state) {
        if (state is LatestNoteLoaded) {
          return _NoteCardContent(note: state.note);
        }
        return const _EmptyNoteCardContent();
      },
    );
  }
}

class _NoteCardContent extends StatelessWidget {
  const _NoteCardContent({required this.note});

  final Note note;

  String _formatTimestamp(DateTime dt) {
    final Duration diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = note.scheme(context);
    final TextTheme tt = Theme.of(context).textTheme;

    final NotePlayerCubit player = locator.isRegistered<NotePlayerCubit>()
        ? locator<NotePlayerCubit>()
        : NotePlayerCubit();

    return BlocBuilder<NotePlayerCubit, NotePlayback>(
      bloc: player,
      builder: (context, playback) {
        final bool isCurrent = playback.noteId == note.id;
        final bool isPlaying = isCurrent && playback.playing;
        final double progress = (isCurrent ? playback.progress : 0.0).clamp(
          0.0,
          1.0,
        );
        final Duration remaining = isCurrent
            ? playback.timeLeft
            : (note.duration ?? Duration.zero);

        final String subtitle;
        if (!note.hasAudio) {
          subtitle = note.audioRecordingFailed
              ? 'Audio recording failed'
              : 'No recording';
        } else if (isPlaying && remaining > Duration.zero) {
          subtitle = '${remaining.remainingLabel} left';
        } else if (note.duration != null && note.duration! > Duration.zero) {
          subtitle = '${note.duration!.remainingLabel} recording';
        } else {
          subtitle = 'Audio attached';
        }

        return GestureDetector(
          onTap: () => NoteDetailPage.open(context, note),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(36),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: -44,
                  right: -44,
                  child: Opacity(
                    opacity: 0.12,
                    child: ClipPath(
                      clipper: ShapeBorderClipper(
                        shape: MaterialShapeBorder(
                          shape: MaterialShapes.sunny,
                        ),
                      ),
                      child: SizedBox(
                        width: 180,
                        height: 180,
                        child: ColoredBox(
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ClipPath(
                            clipper: ShapeBorderClipper(
                              shape: MaterialShapeBorder(
                                shape: MaterialShapes.cookie7Sided,
                              ),
                            ),
                            child: ColoredBox(
                              color: cs.onPrimary.withValues(alpha: 0.2),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: Icon(
                                  note.hasAudio
                                      ? Icons.mic_rounded
                                      : Icons.edit_note_rounded,
                                  color: cs.onPrimary,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'LATEST NOTE • ${_formatTimestamp(note.createdAt).toUpperCase()}',
                            style: tt.labelSmall?.copyWith(
                              color: cs.onPrimary.withValues(alpha: 0.85),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        note.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.unbounded(
                          textStyle: tt.headlineSmall,
                          color: cs.onPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (note.preview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          note.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onPrimary.withValues(alpha: 0.9),
                            height: 1.3,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                WavyLinearProgressIndicator(
                                  value: progress,
                                  color: cs.onPrimary,
                                  trackColor: cs.onPrimary.withValues(
                                    alpha: 0.25,
                                  ),
                                  stopIndicatorColor: cs.onPrimary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  subtitle,
                                  style: tt.labelMedium?.copyWith(
                                    color: cs.onPrimary.withValues(alpha: 0.8),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Material(
                            color: note.hasAudio
                                ? cs.onPrimary
                                : cs.onPrimary.withValues(alpha: 0.35),
                            shape: MaterialShapeBorder(
                              shape: MaterialShapes.cookie7Sided,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: note.hasAudio
                                  ? () => player.toggle(note)
                                  : null,
                              child: SizedBox(
                                width: 64,
                                height: 64,
                                child: Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: note.hasAudio
                                      ? cs.primary
                                      : cs.primary.withValues(alpha: 0.5),
                                  size: 32,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyNoteCardContent extends StatelessWidget {
  const _EmptyNoteCardContent();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Note.schemeFor(context);
    final TextTheme tt = Theme.of(context).textTheme;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(36),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -44,
            right: -44,
            child: Opacity(
              opacity: 0.12,
              child: ClipPath(
                clipper: ShapeBorderClipper(
                  shape: MaterialShapeBorder(
                    shape: MaterialShapes.sunny,
                  ),
                ),
                child: SizedBox(
                  width: 180,
                  height: 180,
                  child: ColoredBox(
                    color: cs.onPrimary,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipPath(
                      clipper: ShapeBorderClipper(
                        shape: MaterialShapeBorder(
                          shape: MaterialShapes.cookie7Sided,
                        ),
                      ),
                      child: ColoredBox(
                        color: cs.onPrimary.withValues(alpha: 0.2),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: Icon(
                            Icons.edit_note_rounded,
                            color: cs.onPrimary,
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'LATEST NOTE',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onPrimary.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'No notes yet',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.unbounded(
                    textStyle: tt.headlineSmall,
                    color: cs.onPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Capture or record your first note to see it here.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(
                    color: cs.onPrimary.withValues(alpha: 0.9),
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          WavyLinearProgressIndicator(
                            value: 0.0,
                            color: cs.onPrimary,
                            trackColor: cs.onPrimary.withValues(alpha: 0.25),
                            stopIndicatorColor: cs.onPrimary,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No recording',
                            style: tt.labelMedium?.copyWith(
                              color: cs.onPrimary.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Material(
                      color: cs.onPrimary.withValues(alpha: 0.35),
                      shape: MaterialShapeBorder(
                        shape: MaterialShapes.cookie7Sided,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: cs.primary.withValues(alpha: 0.5),
                          size: 32,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
