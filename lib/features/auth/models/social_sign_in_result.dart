import 'package:bunpod/bunpod.dart';

class SocialSignInResult {
  const SocialSignInResult({
    required this.provider,
    required this.idToken,
    required this.uid,
    this.email,
    this.name,
    this.accessToken,
    this.refreshToken,
  });

  final AuthProvider provider;
  final String idToken;
  final String uid;
  final String? email;
  final String? name;
  final String? accessToken;
  final String? refreshToken;
}

/// User backed out of the provider sheet.
class SocialSignInCancelled implements Exception {
  const SocialSignInCancelled();

  @override
  String toString() => 'SocialSignInCancelled';
}
