import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

class UserCubit extends Cubit<User?> {
  UserCubit() : super(null);

  Future<void> load() async {
    if (SupabaseConfig.isConfigured) {
      try {
        final sb.User? sbUser = sb.Supabase.instance.client.auth.currentUser;
        if (sbUser != null) {
          emit(User.fromSupabase(sbUser));
          return;
        }
      } catch (_) {
        // Supabase instance not initialized (e.g. In unit tests)
      }
    }

    emit(
      await locator<ProfileRemoteData>().me(),
    );
  }

  void clear() {
    emit(null);
  }
}
