import 'dart:convert';

import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Supabase configuration
//
// Precedence (highest to lowest):
//   1. Build-time --dart-define values loaded from the local .env file
//   2. Placeholder values in assets/config/supabase_config.json
//
// Never put real local configuration in the bundled JSON asset. Use the
// local PowerShell runner documented in README.md to pass the client-safe URL
// and publishable key as build-time defines.
//
// Never pass service-role keys, provider secrets, passwords, or session tokens
// to Flutter. Keep server-only credentials in backend environment variables.
// ---------------------------------------------------------------------------

/// Synchronous compile-time dart-define overrides (empty when not supplied).
abstract final class _DartDefineConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );
}

/// Resolved Supabase configuration.
///
/// Call [load] once during app startup (before [Supabase.initialize]).
/// All other members are safe to read after that call.
abstract final class SupabaseConfig {
  static String _url = '';
  static String _anonKey = '';
  static bool _loaded = false;

  /// URL for the Supabase project.
  static String get url => _url;

  /// Publishable anon key for the Supabase project.
  static String get anonKey => _anonKey;

  /// Alias kept for compatibility.
  static String get publishableKey => _anonKey;

  /// True when both [url] and [anonKey] are non-empty after [load].
  static bool get isConfigured => _url.isNotEmpty && _anonKey.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  /// Placeholder sentinel written into the bundled asset.
  static const String _urlPlaceholder = 'YOUR_SUPABASE_PROJECT_URL';
  static const String _keyPlaceholder = 'YOUR_SUPABASE_ANON_KEY';

  /// Supabase API path segments that must NOT appear in the project URL.
  ///
  /// Users sometimes copy an endpoint URL (e.g. from a curl example) instead
  /// of the bare project URL.  Catching them here produces an actionable error
  /// rather than a confusing 404 from the Supabase client internals.
  static const List<String> _forbiddenSuffixes = <String>[
    '/rest/v1',
    '/auth/v1',
    '/storage/v1',
    '/realtime/v1',
    '/functions/v1',
  ];

  /// Validates the provided [url] and [anonKey].
  ///
  /// Returns an error message when the values are missing, placeholder, or
  /// structurally invalid — null when everything looks good.
  static String? validate({required String url, required String anonKey}) {
    if (url.isEmpty || anonKey.isEmpty) {
      return 'Supabase is not configured.\n'
          'Copy .env.example to .env, add the client-safe settings, and run\n'
          '  .\\scripts\\flutter-run-local.ps1';
    }
    if (url == _urlPlaceholder || anonKey == _keyPlaceholder) {
      return 'Supabase credentials are still placeholders.\n'
          'Copy .env.example to .env, add the client-safe settings, and run\n'
          '  .\\scripts\\flutter-run-local.ps1';
    }
    if (!url.startsWith('https://')) {
      return 'SUPABASE_URL must start with https://\n'
          'Got: ${url.substring(0, url.length.clamp(0, 60))}';
    }
    // Reject endpoint paths — the project URL must be the root only.
    for (final String suffix in _forbiddenSuffixes) {
      if (url.contains(suffix)) {
        return 'SUPABASE_URL contains an API endpoint path ("$suffix").\n'
            'Use only the bare project URL, e.g.:\n'
            '  https://<ref>.supabase.co\n'
            'Remove everything after ".supabase.co".';
      }
    }
    return null;
  }

  /// Returns an error message when the resolved values are missing, still
  /// placeholder, or structurally invalid — null when everything looks good.
  ///
  /// Only checks structure; does not verify that the credentials work at runtime.
  static String? get configError => validate(url: _url, anonKey: _anonKey);

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  /// Loads configuration from the JSON asset, then applies any non-empty
  /// dart-define overrides on top.
  ///
  /// Safe to call more than once; subsequent calls are no-ops.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    // 1. Read the bundled JSON asset.
    String assetUrl = '';
    String assetKey = '';

    try {
      final String raw =
          await rootBundle.loadString('assets/config/supabase_config.json');
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      assetUrl = (json['SUPABASE_URL'] as String? ?? '').trim();
      assetKey = (json['SUPABASE_PUBLISHABLE_KEY'] as String? ??
              json['SUPABASE_ANON_KEY'] as String? ??
              '')
          .trim();
    } catch (_) {
      // Asset missing or malformed — dart-define may still supply the values.
    }

    // 2. Dart-define overrides win when non-empty.
    _url = _DartDefineConfig.url.isNotEmpty ? _DartDefineConfig.url : assetUrl;
    _anonKey = _DartDefineConfig.anonKey.isNotEmpty
        ? _DartDefineConfig.anonKey
        : assetKey;
  }
}
