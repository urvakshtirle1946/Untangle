import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';

class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key});

  static Route<void> route() {
    return MaterialPageRoute<void>(
      builder: (_) {
        return const SubscriptionsPage();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const StyledBackButton(),
        title: const Text('Subscriptions'),
      ),
      body: Center(
        child: Text(
          'No subscriptions yet',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
