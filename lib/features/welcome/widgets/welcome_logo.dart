import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';

class WelcomeLogo extends StatelessWidget {
  const WelcomeLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      AppValues.title,
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
