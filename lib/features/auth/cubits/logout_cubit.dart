import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class LogoutCubit extends Cubit<ViewState> {
  LogoutCubit() : super(const ViewIdle());

  Future<void> logout() async {
    emit(const ViewBusy());

    try {
      final String? refreshToken =
          await locator<SecureStorageLocalData>().refreshToken;

      if (!AppConfig.useMocks && refreshToken != null) {
        try {
          await locator<AuthRemoteData>().logout(refreshToken);
        } catch (_) {}
      }

      await signOut();

      emit(const ViewReady());
    } catch (_) {
      emit(const ViewFailed());
    }
  }
}
