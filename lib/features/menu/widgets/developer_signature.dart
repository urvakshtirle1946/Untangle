import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';

/// Opens the app's attribution details from the menu footer.
class DeveloperSignature extends StatelessWidget {
  const DeveloperSignature({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: () => DeveloperSheet.show(context),
      child: Text(
        'About Untangle',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
