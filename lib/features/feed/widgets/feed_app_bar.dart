import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart'
    hide MaterialShapes, MaterialShapeBorder, RoundedPolygon, CornerRounding;
import 'package:expressive_shapes/expressive_shapes.dart';

class FeedAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FeedAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;

    return AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppValues.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      actions: [
        Tooltip(
          message: 'Search notes',
          child: Material(
            color: cs.secondaryContainer,
            shape: MaterialShapeBorder(
              shape: MaterialShapes.cookie7Sided,
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                NoteSearchPage.show(context);
              },
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  Icons.search_rounded,
                  color: cs.onSecondaryContainer,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) {
                  return MenuPage();
                },
              ),
            );
          },
          customBorder: MaterialShapeBorder(
            shape: MaterialShapes.pill,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(
              shape: MaterialShapeBorder(
                shape: MaterialShapes.pill,
              ),
            ),
            child: const SizedBox(
              width: 40,
              height: 40,
              child: UserAvatar(initials: false),
            ),
          ),
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}
