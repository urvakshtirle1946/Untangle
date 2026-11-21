import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';

class LegalNote extends StatelessWidget {
  const LegalNote({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const .symmetric(horizontal: 32),
      child: Text(
        'Davam etməklə Şərtlər və Məxfilik qaydalarını '
        'qəbul etmiş olursunuz.',
        style: text.bodySmall!.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
