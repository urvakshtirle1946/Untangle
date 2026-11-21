import 'package:bunpod/bunpod.dart';
import 'package:userorient_flutter/userorient_flutter.dart';

Future<void> signOut() async {
  await locator<SecureStorageLocalData>().clearUser();
  await locator<PreferencesLocalData>().clearUser();
  if (locator.isRegistered<PlayerHandler>()) {
    await locator<PlayerHandler>().stop();
  }
  await locator<SocialSignInService>().signOut();
  if (locator.isRegistered<NotePlayerCubit>()) {
    await locator<NotePlayerCubit>().stop();
  }
  await UserOrient.logout();
  if (locator.isRegistered<UserCubit>()) {
    locator<UserCubit>().clear();
  }
  if (locator.isRegistered<SubscriptionsCubit>()) {
    locator<SubscriptionsCubit>().clear();
  }
  if (locator.isRegistered<FeedCubit>()) {
    locator<FeedCubit>().clear();
  }
  if (locator.isRegistered<LatestNoteCubit>()) {
    locator<LatestNoteCubit>().clear();
  }
}
