import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// One instance per sign-in button, so busy always means *this* provider.
class SocialSignInCubit extends Cubit<ViewState> {
  SocialSignInCubit(this.provider) : super(const ViewIdle());

  final AuthProvider provider;

  Future<void> signIn() async {
    if (state is ViewBusy) return;

    emit(const ViewBusy());

    try {
      final SocialSignInResult result = await locator<SocialSignInService>()
          .signIn(provider);

      final String? accessToken = result.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        throw Exception(
          'Sign in failed: no valid access token or session returned.',
        );
      }

      final Tokens tokens = Tokens(
        accessToken: accessToken,
        refreshToken: result.refreshToken ?? '',
      );

      await locator<SecureStorageLocalData>().cacheTokens(tokens);

      if (isClosed) return;

      emit(const ViewReady());
    } on SocialSignInCancelled {
      if (!isClosed) emit(const ViewIdle());
    } catch (error, stackTrace) {
      logarte.log('sign in failed: $error');
      logarte.log('stack trace: $stackTrace');

      if (!isClosed) {
        final String message = error is sb.AuthException
            ? error.message
            : 'Sign in failed. Please try again.';
        emit(ViewFailed(message));
      }
    }
  }
}
