import 'package:bunpod/bunpod.dart';
import 'package:expressive_sheet/expressive_sheet.dart';
import 'package:material_ui/material_ui.dart';

/// Attribution for Untangle and its upstream project.
class DeveloperSheet extends StatelessWidget {
  const DeveloperSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showExpressiveSheet<void>(
      context: context,
      builder: (context) => const DeveloperSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, BottomPadding.of(context)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(52),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'About Untangle',
                  textAlign: TextAlign.center,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Text(
                  'Untangle is adapted from BunPod by Kamran Bekirov under '
                  'the Apache License 2.0, with the author’s written '
                  'permission. Modified by Urvaksh Tirle.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
