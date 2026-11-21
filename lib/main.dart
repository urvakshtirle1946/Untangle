import 'package:bunpod/bunpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:userorient_flutter/userorient_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load Supabase configuration from the bundled asset, then apply any
  // --dart-define overrides on top.
  await SupabaseConfig.load();

  final String? configErr = SupabaseConfig.configError;
  if (configErr != null) {
    // Configuration is missing or still a placeholder.
    // Show a clear setup error instead of crashing or silently proceeding.
    runApp(_ConfigErrorApp(message: configErr));
    return;
  }

  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  ErrorWidget.builder = (details) {
    return FriendlyErrorView(
      details: details,
    );
  };

  UserOrient.configure(
    apiKey: AppConfig.userOrientApiKey,
    accentColor: MaterialThemes.light.colorScheme.primary,
    darkAccentColor: MaterialThemes.dark.colorScheme.primary,
  );

  await setupLocator();
  await clearStaleSecureStorage();

  // Restore session from the Supabase client.  A former Firebase token stored
  // in secure storage is never treated as a Supabase session because:
  //   • Supabase.instance.client.auth.currentSession returns null for it.
  //   • clearStaleSecureStorage() wipes the keychain on a fresh install.
  //   • If no session is found we clear the keychain entry explicitly below.
  final Session? session = Supabase.instance.client.auth.currentSession;
  final bool signedIn;

  if (session != null) {
    signedIn = true;
    // Keep local token cache in sync with the restored Supabase session so the
    // Dio interceptor always has a fresh access token.
    await locator<SecureStorageLocalData>().cacheTokens(
      Tokens(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken ?? '',
      ),
    );
  } else {
    signedIn = false;
    // Isolate and clear any stale token that was cached from a previous
    // Firebase session or a partial Supabase sign-in so it can never act as a
    // second auth authority.
    await locator<SecureStorageLocalData>().clearUser();
  }

  runApp(App(signedIn: signedIn));
}

// ---------------------------------------------------------------------------
// Config error screen
// ---------------------------------------------------------------------------

/// Shown when Supabase credentials are missing or still placeholders.
///
/// Provides the MaterialApp scaffolding used throughout the app.
/// No network calls or sign-in flows are attempted from this state.
class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppValues.title,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: MaterialThemes.light,
      darkTheme: MaterialThemes.dark,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.warning_amber_rounded, size: 48),
                const SizedBox(height: 24),
                Text(
                  'Setup required',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
