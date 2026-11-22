import 'package:flutter/foundation.dart' show listEquals;
import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;
import 'package:flutter/rendering.dart';
import 'package:expressive_shapes/expressive_shapes.dart';
import 'package:motor/motor.dart';

class _Tab {
  const _Tab({
    this.category,
    this.channel,
    required this.label,
    required this.accent,
    required this.onAccent,
    this.image,
    this.shape,
    this.icon,
  });

  final String? category;
  final Channel? channel;
  final String label;
  final Color accent;
  final Color onAccent;
  final String? image;
  final RoundedPolygon? shape;
  final IconData? icon;

  String get tabKey => category != null
      ? 'cat_${category!.toLowerCase()}'
      : (channel != null ? 'chan_${channel!.id}' : 'all');
}

/// Horizontal, single-select filter strip. The selected pill fills with its
/// own accent, morphs squarish → fully-rounded, and is auto-scrolled
/// into view (centered) like a Material scrollable TabBar.
class FeedChannelTabs extends StatefulWidget {
  const FeedChannelTabs({
    super.key,
    this.categories = const <String>[],
    this.selectedCategory,
    this.onCategorySelected,
    this.channels = const <Channel>[],
    this.selected,
    this.onSelected,
    this.height = 44,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<String> categories;
  final String? selectedCategory;
  final ValueChanged<String?>? onCategorySelected;

  final List<Channel> channels;
  final Channel? selected;
  final ValueChanged<Channel?>? onSelected;
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  State<FeedChannelTabs> createState() => _FeedChannelTabsState();
}

class _FeedChannelTabsState extends State<FeedChannelTabs>
    with SingleTickerProviderStateMixin {
  final Map<String, GlobalKey> _keys = {};

  final _scroll = ScrollController();

  // Spring that drives the scroll offset. Standard (not expressive) spatial /
  // fast token: the strip is navigation chrome, so it centers quickly and calmly
  // without the attention-grabbing overshoot of the expressive springs.
  late final SingleMotionController _scrollMotion =
      SingleMotionController(
        motion: MaterialSpringMotion.standardSpatialFast(),
        vsync: this,
      )..addListener(() {
        if (!_scroll.hasClients) return;
        final p = _scroll.position;
        _scroll.jumpTo(
          _scrollMotion.value.clamp(p.minScrollExtent, p.maxScrollExtent),
        );
      });

  bool get _isCategoryMode =>
      widget.onCategorySelected != null || widget.categories.isNotEmpty;

  String get _selectedKey {
    if (_isCategoryMode) {
      return widget.selectedCategory != null
          ? 'cat_${widget.selectedCategory!.toLowerCase()}'
          : 'all';
    }
    return widget.selected != null ? 'chan_${widget.selected!.id}' : 'all';
  }

  @override
  void initState() {
    super.initState();
    if (_selectedKey != 'all') _scrollToSelected();
  }

  @override
  void didUpdateWidget(FeedChannelTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedCategory != widget.selectedCategory ||
        oldWidget.selected != widget.selected ||
        !listEquals(oldWidget.categories, widget.categories)) {
      _scrollToSelected();
    }
  }

  @override
  void dispose() {
    _scrollMotion.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final keyContext = _keys[_selectedKey]?.currentContext;
      final box = keyContext?.findRenderObject();
      if (box is! RenderBox) return;

      final p = _scroll.position;
      final viewport = RenderAbstractViewport.of(box);
      final current = _scroll.offset;

      // Keep the selected chip within the comfortable middle band (25%..75% of
      // the viewport) rather than dead-center. If it's already in that band,
      // leave it. If it has drifted into the outer 25% margin (jammed near an
      // edge), nudge it just to the margin line so the neighbouring chip peeks
      // in — no full recenter.
      final near = viewport
          .getOffsetToReveal(box, 0.25)
          .offset; // 25% from lead
      final far = viewport
          .getOffsetToReveal(box, 0.75)
          .offset; // 25% from trail
      final lo = far < near ? far : near;
      final hi = far < near ? near : far;
      if (current >= lo - 0.5 && current <= hi + 0.5) return;

      final target = (current < lo ? lo : hi).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
      _scrollMotion.animateTo(target, from: current);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    final List<_Tab> tabs;
    if (_isCategoryMode) {
      tabs = [
        _Tab(
          category: null,
          label: 'All',
          accent: cs.primary,
          onAccent: cs.onPrimary,
          icon: Icons.grid_view_rounded,
        ),
        for (final String cat in widget.categories) ...[
          () {
            final ColorScheme catScheme = Note.schemeForCategory(context, cat);
            return _Tab(
              category: cat,
              label: cat,
              accent: catScheme.primary,
              onAccent: catScheme.onPrimary,
            );
          }(),
        ],
      ];
    } else {
      tabs = [
        _Tab(
          channel: null,
          label: 'All',
          accent: cs.primary,
          onAccent: cs.onPrimary,
          icon: Icons.grid_view_rounded,
        ),
        for (final Channel channel in widget.channels)
          _Tab(
            channel: channel,
            label: channel.title ?? '',
            accent: channel.scheme(context).primary,
            onAccent: channel.scheme(context).onPrimary,
            image: channel.image,
            shape: ShapeValues.coverFocused,
          ),
      ];
    }

    Widget buildChip(_Tab tab) {
      final bool isSelected = _isCategoryMode
          ? (tab.category == null
                ? widget.selectedCategory == null
                : widget.selectedCategory?.toLowerCase() ==
                      tab.category?.toLowerCase())
          : tab.channel?.id == widget.selected?.id;

      return _FilterChip(
        key: _keys.putIfAbsent(tab.tabKey, GlobalKey.new),
        tab: tab,
        selected: isSelected,
        onTap: () {
          if (_isCategoryMode) {
            widget.onCategorySelected?.call(tab.category);
          } else {
            widget.onSelected?.call(tab.channel);
          }
        },
      );
    }

    return SizedBox(
      height: widget.height,
      child: _isCategoryMode
          ? SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              child: Row(children: tabs.map(buildChip).toList()),
            )
          : ListView.builder(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              itemCount: tabs.length,
              itemBuilder: (_, i) => buildChip(tabs[i]),
            ),
    );
  }
}

/// A single pill. Fills with the tab's accent when selected, otherwise sits on a
/// calm surface. Material animates both the color and the shape morph.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  // Idle corner radius. The selected chip springs out to a full pill.
  static const double _idleRadius = 12;
  static const double _pillRadius = 22;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      // Selection morph driven by a spring: as a chip becomes selected, `t`
      // springs 0 -> 1, rounding the corners squarish -> pill and drenching the
      // fill in its accent. Standard (calm) spatial/fast spring, since the strip
      // is chrome and shouldn't pull attention with an expressive overshoot.
      child: SingleMotionBuilder(
        motion: MaterialSpringMotion.standardSpatialFast(),
        value: selected ? 1.0 : 0.0,
        builder: (context, t, _) {
          final tc = t.clamp(0.0, 1.0);
          final bg = Color.lerp(cs.surfaceContainerHigh, tab.accent, tc)!;
          final fg = Color.lerp(cs.onSurfaceVariant, tab.onAccent, tc)!;
          final radius = _idleRadius + (_pillRadius - _idleRadius) * t;

          return Material(
            color: bg,
            // Let the spring be the sole driver: no implicit Material tween.
            animationDuration: Duration.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(
                Radius.circular(radius < 0 ? 0 : radius),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tab.image != null ? 6 : 14,
                  6,
                  16,
                  6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.image != null) ...[
                      ClipPath(
                        // Idle covers stay calm circles; only the selected
                        // chip's cover morphs to its expressive material shape.
                        clipper: ShapeBorderClipper(
                          shape: MaterialShapeBorder(
                            shape: selected
                                ? (tab.shape ?? MaterialShapes.circle)
                                : MaterialShapes.circle,
                          ),
                        ),
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: SmoothImage(
                            url: tab.image!,
                            placeholderColor: cs.surfaceContainerHighest,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ] else if (tab.icon != null) ...[
                      Icon(tab.icon, size: 18, color: fg),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      tab.label,
                      style: tt.labelLarge?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
