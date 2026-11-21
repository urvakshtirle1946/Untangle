/// Injected via `--dart-define-from-file=local.json`. Empty means mocks.
abstract final class AppConfig {
  static const String baseUrl = String.fromEnvironment('BASE_URL');

  /// No backend configured, so every remote service is swapped for a mock.
  static bool get useMocks => baseUrl.isEmpty;

  /// Google Cloud Web OAuth client ID. Can be overridden via dart-define.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '353636143935-ot887v83hfuj6gon8l4dromms4b1228m.apps.googleusercontent.com',
  );

  /// iOS only. Reversed form goes in `ios/Flutter/Secrets.xcconfig`.
  static const String googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );

  static const String userOrientApiKey = String.fromEnvironment(
    'USERORIENT_API_KEY',
  );
}
