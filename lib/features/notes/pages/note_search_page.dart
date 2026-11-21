import 'dart:math' as math;

import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;
import 'package:motor/motor.dart';

/// Full-screen note search.
///
/// Searches the signed-in user's saved notes by title and transcript text.
/// Tapping a result navigates to [NoteDetailPage].
///
/// Podcast / channel search is intentionally absent from this path.
class NoteSearchPage extends StatefulWidget {
  const NoteSearchPage({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const NoteSearchPage()),
    );
  }

  @override
  State<NoteSearchPage> createState() => _NoteSearchPageState();
}

class _NoteSearchPageState extends State<NoteSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  // All notes available to search (loaded once from LatestNoteCubit state).
  List<Note> _allNotes = <Note>[];
  List<Note> _results = <Note>[];

  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  void _loadNotes() {
    // Pull the already-loaded notes from LatestNoteCubit so we never
    // hit the network or duplicate repository calls.
    final LatestNoteCubit cubit = locator.isRegistered<LatestNoteCubit>()
        ? locator<LatestNoteCubit>()
        : LatestNoteCubit();

    setState(() {
      _allNotes = List<Note>.from(cubit.state.notes);
      _results = <Note>[];
    });
  }

  void _onChanged(String query) {
    setState(() {
      final String q = query.trim().toLowerCase();
      if (q.isEmpty) {
        _results = <Note>[];
      } else {
        _results = _allNotes.where((Note n) {
          return n.title.toLowerCase().contains(q) ||
              n.bodyText.toLowerCase().contains(q);
        }).toList();
      }
    });
  }

  void _clear() {
    _controller.clear();
    _onChanged('');
  }

  bool _onScroll(ScrollUpdateNotification notification) {
    final bool scrolled = notification.metrics.pixels > 0;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final bool hasQuery = _controller.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          // ── Search field ────────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 16,
              16,
              16,
            ),
            child: _NoteSearchField(
              controller: _controller,
              focusNode: _focus,
              scrolled: _scrolled,
              onChanged: _onChanged,
              onClear: _clear,
            ),
          ),

          // ── Results / states ─────────────────────────────────────────────
          Expanded(
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: _onScroll,
              child: CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  if (!hasQuery)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 48,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.35,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Search your notes',
                              style: tt.titleMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Type to search by title or content.',
                              style: tt.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (_results.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 48,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.35,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No notes found',
                              style: tt.titleMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      sliver: SliverList.builder(
                        itemCount: _results.length,
                        itemBuilder: (BuildContext ctx, int i) {
                          final Note note = _results[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _NoteResultTile(note: note),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Note search field — reuses the ExploreSearchField visual design
// (pill shape, SingleMotionBuilder scroll tint, animated clear button).
// ─────────────────────────────────────────────────────────────────────────────
class _NoteSearchField extends StatelessWidget {
  const _NoteSearchField({
    required this.controller,
    required this.focusNode,
    required this.scrolled,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool scrolled;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    final Widget content = SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 16),
          // Back navigation remains inside the search row on this full-screen route.
          IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Back',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 4),
          Icon(Icons.search_rounded, color: cs.onSurface),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              autofocus: true,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: cs.primary,
              style: tt.bodyLarge?.copyWith(color: cs.onSurface, height: 1),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search notes…',
                hintStyle: tt.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _AnimatedClearButton(
              visible: controller.text.isNotEmpty,
              onPressed: onClear,
            ),
          ),
        ],
      ),
    );

    return SingleMotionBuilder(
      motion: const MaterialSpringMotion.standardEffectsFast(),
      value: scrolled ? 1.0 : 0.0,
      active: !reduceMotion,
      builder: (BuildContext ctx, double t, Widget? child) {
        return Material(
          color: Color.lerp(
            cs.surfaceContainerHigh,
            cs.surfaceContainerHighest,
            t.clamp(0.0, 1.0),
          ),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
      },
      child: content,
    );
  }
}

class _AnimatedClearButton extends StatelessWidget {
  const _AnimatedClearButton({
    required this.visible,
    required this.onPressed,
  });

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SingleMotionBuilder(
      motion: const MaterialSpringMotion.expressiveSpatialFast(),
      value: visible ? 1.0 : 0.0,
      active: !MediaQuery.disableAnimationsOf(context),
      builder: (BuildContext ctx, double t, Widget? button) {
        return IgnorePointer(
          ignoring: !visible,
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.rotate(
              angle: (1 - t) * -math.pi / 2,
              child: Transform.scale(
                scale: math.max(t, 0),
                child: button,
              ),
            ),
          ),
        );
      },
      child: IconButton(
        onPressed: onPressed,
        tooltip: 'Clear',
        icon: Icon(
          Icons.close_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result tile — reuses the same card style as _FeedNoteTile (category tint,
// scheme-aware text) without duplicating layout logic here.
// ─────────────────────────────────────────────────────────────────────────────
class _NoteResultTile extends StatelessWidget {
  const _NoteResultTile({required this.note});

  final Note note;

  String _formatDate(DateTime dt) {
    final Duration diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme noteScheme = note.scheme(context);
    final TextTheme tt = Theme.of(context).textTheme;

    return Material(
      color: noteScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => NoteDetailPage.open(context, note),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: noteScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(note.createdAt),
                    style: tt.bodySmall?.copyWith(
                      color: noteScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (note.preview.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  note.preview,
                  style: tt.bodyMedium?.copyWith(
                    color: noteScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (note.hasCategory) ...<Widget>[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: noteScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    note.category!,
                    style: tt.labelSmall?.copyWith(
                      color: noteScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
