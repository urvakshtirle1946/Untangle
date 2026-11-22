import 'package:bunpod/common/data_sources/preferences_local_data.dart';
import 'package:bunpod/common/helpers/locator.dart';
import 'package:bunpod/features/menu/cubits/theme_mode_cubit.dart';
import 'package:bunpod/features/menu/pages/menu_page.dart';
import 'package:bunpod/features/profile/cubits/user_cubit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _packageInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await locator.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    locator.registerSingleton<PreferencesLocalData>(
      PreferencesLocalData(
        sharedPreferences: await SharedPreferences.getInstance(),
      ),
    );
    locator.registerSingleton<ThemeModeCubit>(ThemeModeCubit());
    locator.registerSingleton<UserCubit>(UserCubit());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, (MethodCall call) async {
          if (call.method != 'getAll') return null;
          return <String, dynamic>{
            'appName': 'Untangle',
            'packageName': 'app.bunpod',
            'version': '1.0.0',
            'buildNumber': '1',
            'buildSignature': '',
            'installerStore': null,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, null);
    await locator.reset();
  });

  testWidgets(
    'Subscriptions remains and no Playlist or Podcasts section appears',
    (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: MenuPage()));
      await tester.pump();

      expect(find.text('Subscriptions'), findsOneWidget);
      expect(find.text('Coming soon'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Playlist'), findsNothing);
      expect(find.text('Playlists'), findsNothing);
      expect(find.text('Podcasts'), findsNothing);

      final Finder suggestFeature = find.text('Suggest a feature');
      await tester.ensureVisible(suggestFeature);
      await tester.tap(suggestFeature);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feedback-message')), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(
        find.textContaining('draft includes your account ID'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Subscriptions entry is marked coming soon and does not navigate', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MenuPage()));
    await tester.pump();

    final Finder subscriptionsEntry = find.text('Subscriptions');
    await tester.ensureVisible(subscriptionsEntry);
    await tester.tap(subscriptionsEntry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Subscriptions'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('No subscriptions yet'), findsNothing);
    expect(find.byType(MenuPage), findsOneWidget);
  });
}
