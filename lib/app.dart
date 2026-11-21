import 'dart:async';

import 'package:bunpod/bunpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class App extends StatefulWidget {
  const App({super.key, required this.signedIn});

  /// Tokens were cached or session active at startup.
  final bool signedIn;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  StreamSubscription<AuthState>? _authSubscription;
  bool _signedOutHandled = false;

  @override
  void initState() {
    super.initState();
    if (SupabaseConfig.isConfigured) {
      _authSubscription = Supabase.instance.client.auth.onAuthStateChange
          .listen(
            (data) {
              final AuthChangeEvent event = data.event;
              if (event == AuthChangeEvent.signedOut) {
                _onSignedOut();
              } else if (event == AuthChangeEvent.signedIn ||
                  event == AuthChangeEvent.tokenRefreshed ||
                  event == AuthChangeEvent.userUpdated) {
                _signedOutHandled = false;
                final Session? session = data.session;
                if (session != null) {
                  locator<SecureStorageLocalData>()
                      .cacheTokens(
                        Tokens(
                          accessToken: session.accessToken,
                          refreshToken: session.refreshToken ?? '',
                        ),
                      )
                      .ignore();
                }
                if (data.session?.user != null) {
                  locator<UserCubit>().load().ignore();
                  if (locator.isRegistered<LatestNoteCubit>()) {
                    locator<LatestNoteCubit>().load().ignore();
                  }
                }
              }
            },
          );
    }
  }

  void _onSignedOut() {
    if (_signedOutHandled) return;
    _signedOutHandled = true;

    signOut().then((_) {
      final NavigatorState? nav = navigatorKey.currentState;
      if (nav != null && nav.mounted) {
        nav.pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => const WelcomePage(farewell: Farewell.logout),
          ),
          (_) => false,
        );
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeModeCubit, ThemeMode>(
      bloc: locator<ThemeModeCubit>(),
      builder: (context, state) {
        final ThemeMode themeMode = state;

        return MaterialApp(
          title: AppValues.title,
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: MaterialThemes.light,
          darkTheme: MaterialThemes.dark,
          builder: (context, child) {
            final MediaQueryData mediaQueryData = MediaQuery.of(context);

            return MediaQuery(
              data: mediaQueryData.copyWith(
                textScaler: mediaQueryData.textScaler.clamp(
                  maxScaleFactor: 1.1,
                ),
              ),
              child: VersionarteWrapper(
                child: child!,
              ),
            );
          },
          home: widget.signedIn ? const FeedPage() : const WelcomePage(),
        );
      },
    );
  }
}
