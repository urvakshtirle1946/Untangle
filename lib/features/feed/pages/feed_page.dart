import 'package:bunpod/bunpod.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:expressive_refresh_indicator/expressive_refresh_indicator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  bool _onboardingShown = false;

  @override
  void initState() {
    super.initState();
    _load();

    locator<UserCubit>().load();
    if (locator.isRegistered<LatestNoteCubit>()) {
      locator<LatestNoteCubit>().load();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      logarte.attach(
        context: context,
        visible: false,
      );
    });
  }

  Future<void> _load() => locator<SubscriptionsCubit>().load();

  Future<void> _showOnboarding() async {
    _onboardingShown = true;

    final bool? followed = await OnboardingPage.show(context);

    if (followed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return BlocConsumer<SubscriptionsCubit, List<Channel>?>(
      bloc: locator<SubscriptionsCubit>(),
      listener: (context, channels) {
        if (channels != null && channels.isEmpty && !_onboardingShown) {
          _showOnboarding();
        }
      },
      builder: (context, channels) {
        if (channels != null && channels.isNotEmpty) {
          return _FeedView(
            key: ValueKey<String>(channels.map((p) => p.id).join('|')),
            channels: channels,
          );
        }

        return Scaffold(
          backgroundColor: cs.surface,
          appBar: FeedAppBar(),
          body: Center(
            child: channels == null
                ? LoadingIndicator()
                : TextButton(
                    onPressed: _showOnboarding,
                    child: const Text('Pick some shows'),
                  ),
          ),
        );
      },
    );
  }
}

class _FeedView extends StatefulWidget {
  const _FeedView({super.key, required this.channels});

  final List<Channel> channels;

  @override
  State<_FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<_FeedView> {
  final _notesScroll = GlobalKey<NestedScrollViewState>();

  Future<void> _composeNote(LatestNoteCubit cubit) async {
    final Note? note = await CreateNoteScreen.open(
      context,
      latestNoteCubit: cubit,
    );
    if (!mounted || note == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final state = cubit.state;
    final bool categoryMatches =
        note.category != null &&
        state.selectedCategory?.toLowerCase() ==
            note.category!.trim().toLowerCase();
    final bool noteInFilter = state.filteredNotes.any(
      (item) => item.id == note.id,
    );
    debugPrint(
      '[note-category] event=feed_after_pop category_matches=$categoryMatches '
      'saved_note_visible=$noteInFilter',
    );
    if (!categoryMatches || !noteInFilter) return;
    final scroll = _notesScroll.currentState;
    if (scroll == null) return;
    if (scroll.innerController.hasClients) {
      scroll.innerController.jumpTo(
        scroll.innerController.position.minScrollExtent,
      );
    }
    if (scroll.outerController.hasClients) {
      scroll.outerController.jumpTo(
        scroll.outerController.position.maxScrollExtent,
      );
    }
  }

  Episode? _playing;

  @override
  void initState() {
    super.initState();
    locator<FeedCubit>().load();
    _playing =
        locator<PreferencesLocalData>().lastEpisode ??
        _firstPlaying(locator<FeedCubit>().state);
  }

  Episode? _firstPlaying(List<Episode>? episodes) {
    if (episodes == null || episodes.isEmpty) return null;

    return episodes.firstWhere(
      (e) => e.listened > Duration.zero && e.progress < 1,
      orElse: () => episodes.first,
    );
  }

  Future<void> _refresh() async {
    if (locator.isRegistered<LatestNoteCubit>()) {
      await locator<LatestNoteCubit>().load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;

    final LatestNoteCubit noteCubit = locator.isRegistered<LatestNoteCubit>()
        ? locator<LatestNoteCubit>()
        : LatestNoteCubit();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: FeedAppBar(),
      body: Stack(
        children: [
          // ── Main scrollable content ────────────────────────────────────────
          ExpressiveRefreshIndicator(
            onRefresh: _refresh,
            notificationPredicate: (notification) =>
                notification.depth >= 1 && notification.depth <= 2,
            child: NestedScrollView(
              key: _notesScroll,
              headerSliverBuilder: (context, innerScrolled) {
                return [
                  SliverToBoxAdapter(
                    child: _NowPlaying(suggested: _playing),
                  ),
                  SliverOverlapAbsorber(
                    handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                      context,
                    ),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _PinnedTabsDelegate(
                        height: 64,
                        child: Center(
                          child: BlocBuilder<LatestNoteCubit, LatestNoteState>(
                            bloc: noteCubit,
                            builder: (context, noteState) {
                              return FeedChannelTabs(
                                categories: noteState.categories,
                                selectedCategory: noteState.selectedCategory,
                                onCategorySelected: (cat) {
                                  HapticsHelper.selection();
                                  noteCubit.selectCategory(cat);
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ];
              },
              body: BlocConsumer<LatestNoteCubit, LatestNoteState>(
                bloc: noteCubit,
                listenWhen: (previous, current) =>
                    previous.selectedCategory != current.selectedCategory ||
                    previous.filteredNotes.length !=
                        current.filteredNotes.length,
                listener: (_, state) {
                  debugPrint(
                    '[note-category] event=feed_state_received '
                    'category_selected=${state.selectedCategory != null} '
                    'filtered_notes=${state.filteredNotes.length}',
                  );
                },
                builder: (context, noteState) {
                  final List<Note> notes = noteState.filteredNotes;
                  return CustomScrollView(
                    slivers: [
                      SliverOverlapInjector(
                        handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                          context,
                        ),
                      ),
                      if (notes.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.notes_rounded,
                                    size: 48,
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    noteState.selectedCategory == null
                                        ? 'No notes yet'
                                        : 'No notes in "${noteState.selectedCategory}"',
                                    style: tt.titleMedium?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Notes will appear here once saved.',
                                    textAlign: TextAlign.center,
                                    style: tt.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.7,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                          sliver: SliverList.builder(
                            itemCount: notes.length,
                            itemBuilder: (context, index) {
                              final Note note = notes[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _FeedNoteTile(note: note),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),

          // ── Styled FAB — matches search-button frame ───────────────────────
          // cookie7Sided shape · secondaryContainer fill · InkWell ripple
          Positioned(
            right: 16,
            bottom: BottomPadding.of(context) + 16,
            child: Tooltip(
              message: 'New note',
              child: Material(
                color: cs.secondaryContainer,
                shape: MaterialShapeBorder(
                  shape: MaterialShapes.cookie7Sided,
                ),
                clipBehavior: Clip.antiAlias,
                elevation: 3,
                child: InkWell(
                  onTap: () {
                    HapticsHelper.selection();
                    _composeNote(noteCubit);
                  },
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(
                      Icons.add_rounded,
                      color: cs.onSecondaryContainer,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedNoteTile extends StatelessWidget {
  const _FeedNoteTile({required this.note});

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
    // noteScheme is derived from the note's category seed (or neutralSeed for
    // uncategorized notes), matching FeedEpisodeCard's cs.surfaceContainerHigh
    // background pattern so the whole card gets a soft category tint.
    final ColorScheme noteScheme = note.scheme(context);
    final TextTheme tt = Theme.of(context).textTheme;

    return Material(
      // Use the note's scheme surface instead of the app-global surface, so
      // the card background carries a subtle category tint (same approach as
      // FeedEpisodeCard's cs.surfaceContainerHigh).
      color: noteScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NoteDetailPage(note: note),
            ),
          );
        },
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
                        // Coordinated with the card surface for readability.
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
              if (note.preview.isNotEmpty) ...[
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
              const SizedBox(height: 10),
              Row(
                children: [
                  if (note.hasCategory) ...[
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
                    const SizedBox(width: 8),
                  ],
                  if (note.hasAudio) ...[
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 16,
                      color: noteScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      note.duration != null
                          ? '${note.duration!.inMinutes}m recording'
                          : 'Recording',
                      style: tt.labelSmall?.copyWith(
                        color: noteScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({this.suggested});

  final Episode? suggested;

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: LatestNoteCard(),
    );
  }
}

class _PinnedTabsDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;

  _PinnedTabsDelegate({
    required this.child,
    required this.height,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox.expand(child: child),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedTabsDelegate old) {
    return old.child != child || old.height != height;
  }
}
