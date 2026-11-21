import 'dart:convert';
import 'dart:math';

import 'package:bunpod/bunpod.dart' hide User;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Signs in with Google or Apple through Supabase and returns its credentials.
class SocialSignInService {
  const SocialSignInService();

  sb.SupabaseClient get _supabase => sb.Supabase.instance.client;

  Future<SocialSignInResult> signIn(AuthProvider provider) {
    return switch (provider) {
      AuthProvider.google => _signInWithGoogle(),
      AuthProvider.apple => _signInWithApple(),
    };
  }

  Future<void> signOut() async {
    try {
      if (SupabaseConfig.isConfigured) {
        await _supabase.auth.signOut();
      }
    } catch (e) {
      logarte.log('Supabase signOut error: $e');
    }

    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  Future<SocialSignInResult> _signInWithGoogle() async {
    await GoogleSignIn.instance.initialize(
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? AppConfig.googleIosClientId
          : null,
      serverClientId: AppConfig.googleServerClientId,
    );

    late final GoogleSignInAccount account;

    try {
      account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email', 'profile'],
      );
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const SocialSignInCancelled();
      }

      rethrow;
    }

    final String? googleIdToken = account.authentication.idToken;

    if (googleIdToken == null) {
      throw Exception('Google did not return an ID token');
    }

    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Supabase is not configured. Real sign-in requires Supabase credentials.',
      );
    }

    final sb.AuthResponse response = await _supabase.auth.signInWithIdToken(
      provider: sb.OAuthProvider.google,
      idToken: googleIdToken,
    );

    final sb.User? user = response.user;
    final sb.Session? session = response.session;
    if (user == null || session == null) {
      throw Exception('Supabase returned no valid session for Google sign-in');
    }

    return SocialSignInResult(
      provider: AuthProvider.google,
      idToken: googleIdToken,
      uid: user.id,
      email: user.email ?? account.email,
      name:
          user.userMetadata?['full_name'] as String? ??
          user.userMetadata?['name'] as String? ??
          account.displayName,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
  }

  Future<SocialSignInResult> _signInWithApple() async {
    final String rawNonce = _generateNonce();

    late final AuthorizationCredentialAppleID appleCredential;

    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: _sha256(rawNonce),
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const SocialSignInCancelled();
      }

      rethrow;
    }

    final String? idToken = appleCredential.identityToken;
    if (idToken == null) {
      throw Exception('Apple did not return an identity token');
    }

    final String? appleName = [
      appleCredential.givenName,
      appleCredential.familyName,
    ].whereType<String>().join(' ').trim().nullIfEmpty;

    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Supabase is not configured. Real sign-in requires Supabase credentials.',
      );
    }

    final sb.AuthResponse response = await _supabase.auth.signInWithIdToken(
      provider: sb.OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );

    sb.User? user = response.user;
    final sb.Session? session = response.session;
    if (user == null || session == null) {
      throw Exception('Supabase returned no valid session for Apple sign-in');
    }

    if (appleName != null &&
        ((user.userMetadata?['full_name'] as String?)?.isEmpty ?? true)) {
      final sb.UserResponse updated = await _supabase.auth.updateUser(
        sb.UserAttributes(
          data: {'full_name': appleName},
        ),
      );
      user = updated.user ?? user;
    }

    return SocialSignInResult(
      provider: AuthProvider.apple,
      idToken: idToken,
      uid: user.id,
      email: user.email,
      name:
          user.userMetadata?['full_name'] as String? ??
          user.userMetadata?['name'] as String? ??
          appleName,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
  }

  String _generateNonce([int length = 32]) {
    const String charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final Random random = Random.secure();

    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }

  String _sha256(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
