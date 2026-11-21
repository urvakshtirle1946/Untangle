import 'package:audio_service/audio_service.dart';
import 'package:bunpod/bunpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// NOTE ON TEST COVERAGE
//
// Tests marked [MOCKED] exercise logic with in-process fakes and do not prove
// runtime behaviour against a live Supabase project.
//
// Tests marked [UNIT] exercise pure Dart logic with no external dependencies.
//
// Runtime behaviour that requires a live Supabase instance (actual Google OAuth
// round-trip, token refresh, RLS enforcement) is NOT covered here and must be
// verified manually — see the manual checklist at the bottom of this file.
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await locator.reset();
  });

  tearDown(() async {
    await locator.reset();
  });

  // -------------------------------------------------------------------------
  // 1. Supabase configuration
  // -------------------------------------------------------------------------
  group('SupabaseConfig — compile-time defaults [UNIT]', () {
    test('url and anonKey are empty when no dart-define is supplied', () {
      // In the test runner no --dart-define flags are passed, so the
      // fromEnvironment constants resolve to their default (empty) strings.
      expect(SupabaseConfig.url, isEmpty);
      expect(SupabaseConfig.anonKey, isEmpty);
      expect(SupabaseConfig.publishableKey, isEmpty);
      expect(SupabaseConfig.isConfigured, isFalse);
    });

    test('configError is non-null when url and anonKey are empty', () {
      // After load() with no asset and no dart-defines, configError must
      // describe what values are needed.
      expect(SupabaseConfig.configError, isNotNull);
      expect(SupabaseConfig.configError, contains('SUPABASE_URL'));
    });
  });

  group('SupabaseConfig — validation [UNIT]', () {
    test('configError is non-null when values match placeholder sentinels', () {
      expect(
        SupabaseConfig.validate(
          url: 'YOUR_SUPABASE_PROJECT_URL',
          anonKey: 'YOUR_SUPABASE_ANON_KEY',
        ),
        contains('still placeholders'),
      );
    });

    test('rejects non-https URLs', () {
      expect(
        SupabaseConfig.validate(
          url: 'http://project.supabase.co',
          anonKey: 'valid-anon-key',
        ),
        contains('must start with https://'),
      );
    });

    test(
      'rejects endpoint suffixes (/rest/v1, /auth/v1, /storage/v1, etc.)',
      () {
        const List<String> invalidUrls = <String>[
          'https://project.supabase.co/rest/v1',
          'https://project.supabase.co/rest/v1/',
          'https://project.supabase.co/auth/v1',
          'https://project.supabase.co/auth/v1/',
          'https://project.supabase.co/storage/v1',
          'https://project.supabase.co/storage/v1/',
          'https://project.supabase.co/realtime/v1',
          'https://project.supabase.co/functions/v1',
        ];

        for (final String badUrl in invalidUrls) {
          final String? error = SupabaseConfig.validate(
            url: badUrl,
            anonKey: 'valid-anon-key',
          );
          expect(
            error,
            isNotNull,
            reason: 'Expected $badUrl to be rejected',
          );
          expect(
            error,
            contains('contains an API endpoint path'),
            reason:
                'Expected error to explain that $badUrl contains endpoint path',
          );
        }
      },
    );

    test('accepts clean project URL and anon key', () {
      expect(
        SupabaseConfig.validate(
          url: 'https://example-project.supabase.co',
          anonKey: 'test-publishable-key',
        ),
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  // 2. Session restoration and signed-out startup [MOCKED]
  // -------------------------------------------------------------------------
  group('Session restoration — signed-out startup [MOCKED]', () {
    test(
      'No token is present in secure storage when no session exists',
      () async {
        const SecureStorageLocalData storage = SecureStorageLocalData();
        // Fresh install: no cached token.
        expect(await storage.accessToken, isNull);
        expect(await storage.refreshToken, isNull);
      },
    );

    test(
      'clearUser removes both access and refresh tokens',
      () async {
        const SecureStorageLocalData storage = SecureStorageLocalData();
        await storage.cacheTokens(
          const Tokens(
            accessToken: 'old-access-token',
            refreshToken: 'old-refresh-token',
          ),
        );
        expect(await storage.accessToken, equals('old-access-token'));

        await storage.clearUser();
        expect(await storage.accessToken, isNull);
        expect(await storage.refreshToken, isNull);
      },
    );

    test(
      'cacheTokens followed by clearAll leaves no tokens',
      () async {
        const SecureStorageLocalData storage = SecureStorageLocalData();
        await storage.cacheTokens(
          const Tokens(
            accessToken: 'tok-a',
            refreshToken: 'tok-r',
          ),
        );
        await storage.clearAll();
        expect(await storage.accessToken, isNull);
        expect(await storage.refreshToken, isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // 3. Account isolation and sign-out [MOCKED]
  // -------------------------------------------------------------------------
  group('Account isolation and sign-out [MOCKED]', () {
    test(
      'signOut clears tokens, preferences, and user/subscription/feed cubits',
      () async {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        final PreferencesLocalData preferences = PreferencesLocalData(
          sharedPreferences: prefs,
        );
        const SecureStorageLocalData secureStorage = SecureStorageLocalData();
        const MockSocialSignInService socialSignIn = MockSocialSignInService();
        final UserCubit userCubit = UserCubit();
        final SubscriptionsCubit subscriptionsCubit = SubscriptionsCubit();
        final FeedCubit feedCubit = FeedCubit();

        locator.registerSingleton<SecureStorageLocalData>(secureStorage);
        locator.registerSingleton<PreferencesLocalData>(preferences);
        locator.registerSingleton<SocialSignInService>(socialSignIn);
        locator.registerSingleton<UserCubit>(userCubit);
        locator.registerSingleton<SubscriptionsCubit>(subscriptionsCubit);
        locator.registerSingleton<FeedCubit>(feedCubit);
        locator.registerSingleton<PlayerHandler>(MockPlayerHandler());

        // Seed user-specific state.
        await secureStorage.cacheTokens(
          const Tokens(
            accessToken: 'test-access-token',
            refreshToken: 'test-refresh-token',
          ),
        );
        await preferences.cacheLastEpisode(
          const Episode(id: 123, title: 'Test Episode'),
        );
        expect(await secureStorage.accessToken, equals('test-access-token'));
        expect(await secureStorage.refreshToken, equals('test-refresh-token'));
        expect(preferences.lastEpisode?.id, equals(123));

        // Trigger sign out.
        await signOut();

        // Verify all isolated user state is cleared.
        expect(await secureStorage.accessToken, isNull);
        expect(await secureStorage.refreshToken, isNull);
        expect(preferences.lastEpisode, isNull);
        expect(userCubit.state, isNull);
        expect(subscriptionsCubit.state, isNull);
        expect(feedCubit.state, isNull);
      },
    );

    test(
      'A second signOut call is idempotent — tokens remain null',
      () async {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );
        locator.registerSingleton<PreferencesLocalData>(
          PreferencesLocalData(sharedPreferences: prefs),
        );
        locator.registerSingleton<SocialSignInService>(
          const MockSocialSignInService(),
        );
        locator.registerSingleton<UserCubit>(UserCubit());
        locator.registerSingleton<SubscriptionsCubit>(SubscriptionsCubit());
        locator.registerSingleton<FeedCubit>(FeedCubit());
        locator.registerSingleton<PlayerHandler>(MockPlayerHandler());

        await signOut();
        await signOut(); // second call must not throw

        expect(
          await locator<SecureStorageLocalData>().accessToken,
          isNull,
        );
      },
    );

    test(
      'User.fromSupabase parses id, email, name, avatar, provider without mock identity',
      () {
        final Map<String, dynamic> fakeSbUser = {
          'id': 'sb-user-123',
          'app_metadata': {'provider': 'google'},
          'user_metadata': {
            'full_name': 'Real Explorer',
            'avatar_url': 'https://example.com/avatar.jpg',
          },
          'email': 'real.user@gmail.com',
          'created_at': '2026-05-01T12:00:00Z',
        };

        final User user = User.fromSupabase(
          _FakeSupabaseUser(
            id: fakeSbUser['id'] as String,
            email: fakeSbUser['email'] as String,
            appMetadata: fakeSbUser['app_metadata'] as Map<String, dynamic>,
            userMetadata: fakeSbUser['user_metadata'] as Map<String, dynamic>,
            createdAt: fakeSbUser['created_at'] as String,
          ),
        );

        expect(user.id, equals('sb-user-123'));
        expect(user.email, equals('real.user@gmail.com'));
        expect(user.name, equals('Real Explorer'));
        expect(user.avatar, equals('https://example.com/avatar.jpg'));
        expect(user.provider, equals('google'));
        expect(user.email, isNot(contains('mock@example.invalid')));
      },
    );

    test(
      'User.fromSupabase handles missing name and avatar with neutral nulls',
      () {
        final User user = User.fromSupabase(
          const _FakeSupabaseUser(
            id: 'sb-minimal-456',
            email: 'minimal@domain.com',
            appMetadata: {'provider': 'google'},
            userMetadata: {},
          ),
        );

        expect(user.id, equals('sb-minimal-456'));
        expect(user.email, equals('minimal@domain.com'));
        expect(user.name, isNull);
        expect(user.avatar, isNull);
        expect(user.email, isNot(contains('mock@example.invalid')));
      },
    );

    test(
      'UserCubit clears identity on signOut and loads new user on account switch',
      () async {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );
        locator.registerSingleton<PreferencesLocalData>(
          PreferencesLocalData(sharedPreferences: prefs),
        );
        locator.registerSingleton<SocialSignInService>(
          const MockSocialSignInService(),
        );
        final UserCubit userCubit = UserCubit();
        locator.registerSingleton<UserCubit>(userCubit);
        locator.registerSingleton<SubscriptionsCubit>(SubscriptionsCubit());
        locator.registerSingleton<FeedCubit>(FeedCubit());
        locator.registerSingleton<PlayerHandler>(MockPlayerHandler());

        // Initial user logged in
        userCubit.emit(
          const User(id: 'user-A', email: 'alice@gmail.com', name: 'Alice'),
        );
        expect(userCubit.state?.email, equals('alice@gmail.com'));

        // Sign out clears state
        await signOut();
        expect(userCubit.state, isNull);

        // Switch to User B
        userCubit.emit(
          const User(id: 'user-B', email: 'bob@gmail.com', name: 'Bob'),
        );
        expect(userCubit.state?.email, equals('bob@gmail.com'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // 4. Cubit state transitions [MOCKED]
  // -------------------------------------------------------------------------
  group('SocialSignInCubit state transitions [MOCKED]', () {
    test(
      'emits ViewBusy then ViewReady on mock success',
      () async {
        locator.registerSingleton<SocialSignInService>(
          const MockSocialSignInService(),
        );
        locator.registerSingleton<AuthRemoteData>(
          const MockAuthRemoteData(),
        );
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );

        final SocialSignInCubit cubit = SocialSignInCubit(AuthProvider.google);
        expect(cubit.state, isA<ViewIdle>());

        final Future<void> signInFuture = cubit.signIn();
        expect(cubit.state, isA<ViewBusy>());

        await signInFuture;
        expect(cubit.state, isA<ViewReady>());

        final String? token =
            await locator<SecureStorageLocalData>().accessToken;
        expect(token, equals('mock-access-token'));
        await cubit.close();
      },
    );

    test(
      'concurrent signIn calls: second call is a no-op while first is in flight',
      () async {
        locator.registerSingleton<SocialSignInService>(
          const MockSocialSignInService(),
        );
        locator.registerSingleton<AuthRemoteData>(
          const MockAuthRemoteData(),
        );
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );

        final SocialSignInCubit cubit = SocialSignInCubit(AuthProvider.google);
        final Future<void> first = cubit.signIn();
        final Future<void> second = cubit.signIn(); // should no-op

        await Future.wait(<Future<void>>[first, second]);
        expect(cubit.state, isA<ViewReady>());
        await cubit.close();
      },
    );

    test(
      'cancelled sign-in emits ViewIdle without navigating or storing tokens',
      () async {
        locator.registerSingleton<SocialSignInService>(
          const _CancellingSocialSignInService(),
        );
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );

        final SocialSignInCubit cubit = SocialSignInCubit(AuthProvider.google);
        await cubit.signIn();

        expect(cubit.state, isA<ViewIdle>());
        expect(await locator<SecureStorageLocalData>().accessToken, isNull);
        await cubit.close();
      },
    );

    test('failed sign-in emits ViewFailed without storing tokens', () async {
      locator.registerSingleton<SocialSignInService>(
        const _FailingSocialSignInService(),
      );
      locator.registerSingleton<SecureStorageLocalData>(
        const SecureStorageLocalData(),
      );

      final SocialSignInCubit cubit = SocialSignInCubit(AuthProvider.google);
      await cubit.signIn();

      expect(cubit.state, isA<ViewFailed>());
      expect(await locator<SecureStorageLocalData>().accessToken, isNull);
      await cubit.close();
    });

    test(
      'sign-in without a session / accessToken throws and emits ViewFailed',
      () async {
        locator.registerSingleton<SocialSignInService>(
          const _SessionlessSocialSignInService(),
        );
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );

        final SocialSignInCubit cubit = SocialSignInCubit(AuthProvider.google);
        await cubit.signIn();

        expect(cubit.state, isA<ViewFailed>());
        expect(await locator<SecureStorageLocalData>().accessToken, isNull);
        await cubit.close();
      },
    );
  });

  group('Service selection via locator [UNIT]', () {
    test('setupLocator registers real SocialSignInService when Supabase is configured', () async {
      // In this test, assets/config/supabase_config.json was loaded or configured
      await SupabaseConfig.load();
      await setupLocator(playerHandler: MockPlayerHandler());

      final SocialSignInService service = locator<SocialSignInService>();
      expect(service, isA<SocialSignInService>());
      expect(service, isNot(isA<MockSocialSignInService>()));
    });
  });

  group('LogoutCubit state transitions [MOCKED]', () {
    test('executes logout and leaves user state cleared', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      locator.registerSingleton<SecureStorageLocalData>(
        const SecureStorageLocalData(),
      );
      locator.registerSingleton<PreferencesLocalData>(
        PreferencesLocalData(sharedPreferences: prefs),
      );
      locator.registerSingleton<SocialSignInService>(
        const MockSocialSignInService(),
      );
      locator.registerSingleton<AuthRemoteData>(const MockAuthRemoteData());
      locator.registerSingleton<UserCubit>(UserCubit());
      locator.registerSingleton<SubscriptionsCubit>(SubscriptionsCubit());
      locator.registerSingleton<FeedCubit>(FeedCubit());
      locator.registerSingleton<PlayerHandler>(MockPlayerHandler());

      final LogoutCubit cubit = LogoutCubit();
      expect(cubit.state, isA<ViewIdle>());

      await cubit.logout();
      expect(cubit.state, isA<ViewReady>());
      expect(
        await locator<SecureStorageLocalData>().accessToken,
        isNull,
      );
      await cubit.close();
    });
  });

  group('Untangle Home & Feed Screen [UNIT]', () {
    testWidgets(
      'FeedAppBar displays Untangle branding, Explore and UserAvatar',
      (
        tester,
      ) async {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        locator.registerSingleton<SecureStorageLocalData>(
          const SecureStorageLocalData(),
        );
        locator.registerSingleton<PreferencesLocalData>(
          PreferencesLocalData(sharedPreferences: prefs),
        );
        locator.registerSingleton<ProfileRemoteData>(
          const MockProfileRemoteData(),
        );
        locator.registerSingleton<UserCubit>(UserCubit());

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              appBar: FeedAppBar(),
            ),
          ),
        );
        await tester.pump();

        // FeedAppBar is present.
        expect(find.byType(FeedAppBar), findsOneWidget);
        expect(find.text('Untangle'), findsOneWidget);
        expect(find.byTooltip('Search notes'), findsOneWidget);
        expect(find.byType(UserAvatar), findsOneWidget);
      },
    );

    testWidgets(
      'FeedSectionHeader renders count badge and label with app styling',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: FeedSectionHeader(
                label: 'Episodes',
                count: 42,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Episodes'), findsOneWidget);
        expect(find.text('42'), findsOneWidget);
      },
    );

    testWidgets(
      'FeedNowPlayingCard displays show, episode title and progress',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: Scaffold(
              body: FeedNowPlayingCard(
                scheme: MaterialThemes.light.colorScheme,
                imageUrl: '',
                channel: 'The Daily',
                title: 'Understanding Modern AI',
                progress: 0.65,
                timeLeft: const Duration(minutes: 12),
                coverShape: ShapeValues.coverFocused,
                playing: false,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('THE DAILY'), findsOneWidget);
        expect(find.text('Understanding Modern AI'), findsOneWidget);
        expect(find.text('12m left'), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // 5. Latest Note Card & Notes Integration [UNIT]
  // -------------------------------------------------------------------------
  group('Latest Note Card & Notes Integration [UNIT]', () {
    test('NotesRepository selects the most recent note for the user and enforces user isolation', () async {
      final InMemoryNotesRepository repo = InMemoryNotesRepository();

      final DateTime now = DateTime.now();
      final Note olderNoteA = Note(
        id: 'note-1',
        userId: 'user-a',
        title: 'Older note from user A',
        preview: 'First thought preview',
        createdAt: now.subtract(const Duration(hours: 2)),
      );
      final Note newerNoteA = Note(
        id: 'note-2',
        userId: 'user-a',
        title: 'Newest note from user A',
        preview: 'Second thought preview',
        createdAt: now.subtract(const Duration(minutes: 10)),
        audioUrl: 'https://example.com/audio-a.m4a',
        duration: const Duration(minutes: 2),
      );
      final Note noteUserB = Note(
        id: 'note-3',
        userId: 'user-b',
        title: 'Note from user B',
        preview: 'User B confidential thought',
        createdAt: now,
      );

      await repo.saveNote(olderNoteA);
      await repo.saveNote(newerNoteA);
      await repo.saveNote(noteUserB);

      // Latest note for user-a must be newerNoteA
      final Note? latestA = await repo.getLatestNote(userId: 'user-a');
      expect(latestA, isNotNull);
      expect(latestA!.id, equals('note-2'));
      expect(latestA.title, equals('Newest note from user A'));

      // Latest note for user-b must be noteUserB, isolated from user-a
      final Note? latestB = await repo.getLatestNote(userId: 'user-b');
      expect(latestB, isNotNull);
      expect(latestB!.id, equals('note-3'));

      // Unauthenticated / unknown user gets null (honest empty)
      final Note? latestUnknown = await repo.getLatestNote(
        userId: 'user-unknown',
      );
      expect(latestUnknown, isNull);
    });

    testWidgets(
      'LatestNoteCard displays honest empty state when there are no notes',
      (tester) async {
        final LatestNoteCubit noteCubit = LatestNoteCubit(
          repository: InMemoryNotesRepository(),
        );
        noteCubit.emit(const LatestNoteEmpty());
        locator.registerSingleton<LatestNoteCubit>(noteCubit);
        locator.registerSingleton<NotePlayerCubit>(NotePlayerCubit());

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('LATEST NOTE'), findsOneWidget);
        expect(find.text('No notes yet'), findsOneWidget);
        expect(
          find.text('Capture or record your first note to see it here.'),
          findsOneWidget,
        );
        expect(find.text('No recording'), findsOneWidget);
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      },
    );

    testWidgets(
      'LatestNoteCard displays note without audio: shows "No recording" and disables audio controls',
      (tester) async {
        final Note noteWithoutAudio = Note(
          id: 'note-no-audio',
          userId: 'user-1',
          title: 'Text-only reflection',
          preview: 'Key insights from architecture meeting.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
          audioUrl: null,
        );

        final LatestNoteCubit noteCubit = LatestNoteCubit(
          repository: InMemoryNotesRepository(),
        );
        noteCubit.emit(LatestNoteLoaded(noteWithoutAudio));
        locator.registerSingleton<LatestNoteCubit>(noteCubit);
        final NotePlayerCubit playerCubit = NotePlayerCubit();
        locator.registerSingleton<NotePlayerCubit>(playerCubit);

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Text-only reflection'), findsOneWidget);
        expect(
          find.text('Key insights from architecture meeting.'),
          findsOneWidget,
        );
        expect(find.text('No recording'), findsOneWidget);

        // Tapping play button does not trigger playback because hasAudio is false
        await tester.tap(find.byIcon(Icons.play_arrow_rounded));
        await tester.pump();
        expect(playerCubit.state.playing, isFalse);
      },
    );

    testWidgets(
      'LatestNoteCard displays note with audio: shows duration and reflects playback',
      (tester) async {
        final Note noteWithAudio = Note(
          id: 'note-audio',
          userId: 'user-1',
          title: 'Voice memo on state sync',
          preview: 'Audio memo discussing real-time channels.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 15)),
          audioUrl: 'https://example.com/recording.m4a',
          duration: const Duration(minutes: 4, seconds: 12),
        );

        final LatestNoteCubit noteCubit = LatestNoteCubit(
          repository: InMemoryNotesRepository(),
        );
        noteCubit.emit(LatestNoteLoaded(noteWithAudio));
        locator.registerSingleton<LatestNoteCubit>(noteCubit);
        final NotePlayerCubit playerCubit = NotePlayerCubit();
        locator.registerSingleton<NotePlayerCubit>(playerCubit);

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Voice memo on state sync'), findsOneWidget);
        expect(find.text('4m recording'), findsOneWidget);

        // Tapping play toggles NotePlayerCubit state
        await tester.tap(find.byIcon(Icons.play_arrow_rounded));
        await tester.pump();
        expect(playerCubit.state.noteId, equals('note-audio'));
        expect(playerCubit.state.playing, isTrue);
      },
    );

    testWidgets(
      'Tapping LatestNoteCard opens NoteDetailPage with note content and status',
      (tester) async {
        final Note note = Note(
          id: 'note-detail-test',
          userId: 'user-1',
          title: 'Design review findings',
          preview: 'Full analysis of responsive card components.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
          audioUrl: null,
        );

        final LatestNoteCubit noteCubit = LatestNoteCubit(
          repository: InMemoryNotesRepository(),
        );
        noteCubit.emit(LatestNoteLoaded(note));
        locator.registerSingleton<LatestNoteCubit>(noteCubit);
        locator.registerSingleton<NotePlayerCubit>(NotePlayerCubit());

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        // Tap card
        await tester.tap(find.text('Design review findings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.byType(NoteDetailPage), findsOneWidget);
        expect(find.text('Note details'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(NoteDetailPage),
            matching: find.text('Full analysis of responsive card components.'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(NoteDetailPage),
            matching: find.text('No recording'),
          ),
          findsOneWidget,
        );
      },
    );

    test('signOut stops note playback and resets LatestNoteCubit', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      locator.registerSingleton<SecureStorageLocalData>(
        const SecureStorageLocalData(),
      );
      locator.registerSingleton<PreferencesLocalData>(
        PreferencesLocalData(sharedPreferences: prefs),
      );
      locator.registerSingleton<SocialSignInService>(
        const MockSocialSignInService(),
      );
      locator.registerSingleton<UserCubit>(UserCubit());
      locator.registerSingleton<SubscriptionsCubit>(SubscriptionsCubit());
      locator.registerSingleton<FeedCubit>(FeedCubit());

      final LatestNoteCubit noteCubit = LatestNoteCubit(
        repository: InMemoryNotesRepository(),
      );
      noteCubit.emit(
        LatestNoteLoaded(
          Note(
            id: 'active-note',
            userId: 'user-1',
            title: 'Active note',
            preview: 'Note before sign-out',
            createdAt: DateTime.now(),
            audioUrl: 'https://example.com/audio.m4a',
          ),
        ),
      );
      locator.registerSingleton<LatestNoteCubit>(noteCubit);

      final NotePlayerCubit playerCubit = NotePlayerCubit();
      playerCubit.emit(
        const NotePlayback(
          noteId: 'active-note',
          playing: true,
          position: Duration(seconds: 45),
          duration: Duration(minutes: 3),
        ),
      );
      locator.registerSingleton<NotePlayerCubit>(playerCubit);

      // Perform signOut
      await signOut();

      // Audio must be stopped and state reset
      expect(playerCubit.state.playing, isFalse);
      expect(playerCubit.state.noteId, isNull);

      // Latest note cubit must be reset to initial
      expect(noteCubit.state, isA<LatestNoteInitial>());
    });

    test('Note seed and ColorScheme derivation is stable and derived from note metadata', () {
      final Note note1 = Note(
        id: 'note-stable-id-1',
        userId: 'user-1',
        title: 'Title 1',
        preview: 'Preview 1',
        createdAt: DateTime.now(),
      );
      final Note note2 = Note(
        id: 'note-stable-id-2',
        userId: 'user-1',
        title: 'Title 2',
        preview: 'Preview 2',
        createdAt: DateTime.now(),
      );

      // Seed must be deterministic across calls (not random)
      expect(note1.seedColor, equals(note1.seedColor));
      expect(note2.seedColor, equals(note2.seedColor));

      // Seeds belong to the app's curated palette.
      expect(Note.palette.contains(note1.seedColor), isTrue);
      expect(Note.palette.contains(note2.seedColor), isTrue);

      // Empty fallback seed is stable
      expect(Note.seedFor(null), equals(Note.palette[2]));
    });

    testWidgets(
      'LatestNoteCard uses note-derived ColorScheme and adapts to dark mode instead of light-green theme default',
      (tester) async {
        final Note note = Note(
          id: 'note-color-test',
          userId: 'user-1',
          title: 'Color test note',
          preview: 'Preview text',
          createdAt: DateTime.now(),
        );

        final LatestNoteCubit noteCubit = LatestNoteCubit(
          repository: InMemoryNotesRepository(),
        );
        noteCubit.emit(LatestNoteLoaded(note));
        locator.registerSingleton<LatestNoteCubit>(noteCubit);
        locator.registerSingleton<NotePlayerCubit>(NotePlayerCubit());

        // 1. Light mode build
        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        // Find the card container
        final Finder cardContainerFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).borderRadius ==
                  BorderRadius.circular(36),
        );
        expect(cardContainerFinder, findsOneWidget);

        final Container lightContainer = tester.widget<Container>(
          cardContainerFinder,
        );
        final BoxDecoration lightDeco =
            lightContainer.decoration! as BoxDecoration;
        final BuildContext context = tester.element(cardContainerFinder);
        final ColorScheme expectedLightScheme = note.scheme(context);

        expect(lightDeco.color, equals(expectedLightScheme.primary));
        // Must NOT be the theme's default primary (which is the light-green/chartreuse color)
        expect(
          lightDeco.color,
          isNot(equals(MaterialThemes.light.colorScheme.primary)),
        );

        // 2. Dark mode build
        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.dark,
            home: const Scaffold(
              body: LatestNoteCard(),
            ),
          ),
        );
        await tester.pump();

        final Container darkContainer = tester.widget<Container>(
          cardContainerFinder,
        );
        final BoxDecoration darkDeco =
            darkContainer.decoration! as BoxDecoration;
        final BuildContext darkContext = tester.element(cardContainerFinder);
        final ColorScheme expectedDarkScheme = note.scheme(darkContext);

        expect(darkDeco.color, equals(expectedDarkScheme.primary));
        expect(
          darkDeco.color,
          isNot(equals(MaterialThemes.dark.colorScheme.primary)),
        );
      },
    );

    test('Category extraction trims whitespace and deduplicates case-insensitively', () {
      final List<Note> notes = [
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'Note 1',
          preview: 'Preview 1',
          createdAt: DateTime.now(),
          category: '  Ideas  ',
        ),
        Note(
          id: 'n2',
          userId: 'u1',
          title: 'Note 2',
          preview: 'Preview 2',
          createdAt: DateTime.now(),
          category: 'ideas',
        ),
        Note(
          id: 'n3',
          userId: 'u1',
          title: 'Note 3',
          preview: 'Preview 3',
          createdAt: DateTime.now(),
          category: 'Work',
        ),
        Note(
          id: 'n4',
          userId: 'u1',
          title: 'Note 4',
          preview: 'Preview 4',
          createdAt: DateTime.now(),
          category: 'WORK',
        ),
        Note(
          id: 'n5',
          userId: 'u1',
          title: 'Note 5',
          preview: 'Preview 5',
          createdAt: DateTime.now(),
          category: null, // uncategorized
        ),
        Note(
          id: 'n6',
          userId: 'u1',
          title: 'Note 6',
          preview: 'Preview 6',
          createdAt: DateTime.now(),
          category: '   ', // whitespace only
        ),
      ];

      final List<String> categories = Note.extractCategories(notes);
      expect(categories, equals(['Ideas', 'Work']));
    });

    test('Note filtering by category: filters case-insensitively and keeps uncategorized in All', () async {
      final InMemoryNotesRepository repo = InMemoryNotesRepository();
      final DateTime now = DateTime.now();

      await repo.saveNote(
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'Idea 1',
          preview: 'Preview',
          createdAt: now.subtract(const Duration(minutes: 10)),
          category: 'Ideas',
        ),
      );
      await repo.saveNote(
        Note(
          id: 'n2',
          userId: 'u1',
          title: 'Idea 2',
          preview: 'Preview',
          createdAt: now.subtract(const Duration(minutes: 5)),
          category: 'ideas', // lowercase
        ),
      );
      await repo.saveNote(
        Note(
          id: 'n3',
          userId: 'u1',
          title: 'Work Note',
          preview: 'Preview',
          createdAt: now.subtract(const Duration(minutes: 2)),
          category: 'Work',
        ),
      );
      await repo.saveNote(
        Note(
          id: 'n4',
          userId: 'u1',
          title: 'Uncategorized Note',
          preview: 'Preview',
          createdAt: now,
          category: null,
        ),
      );

      // 1. Filter by category "Ideas" (case-insensitive)
      final List<Note> ideasNotes = await repo.getNotes(
        userId: 'u1',
        category: 'ideas',
      );
      expect(ideasNotes.map((n) => n.id), containsAll(['n1', 'n2']));
      expect(ideasNotes.map((n) => n.id), isNot(contains('n3')));
      expect(ideasNotes.map((n) => n.id), isNot(contains('n4')));

      // 2. Filter by "All": uncategorized notes remain visible
      final List<Note> allNotes = await repo.getNotes(
        userId: 'u1',
        category: 'All',
      );
      expect(allNotes.map((n) => n.id), containsAll(['n1', 'n2', 'n3', 'n4']));

      // 3. Null category returns all notes as well
      final List<Note> nullCatNotes = await repo.getNotes(
        userId: 'u1',
        category: null,
      );
      expect(nullCatNotes.length, equals(4));
    });

    test('User-category precedence contract: explicit user category always wins over AI category', () async {
      final Note initialNote = Note(
        id: 'prec-1',
        userId: 'u1',
        title: 'Precedence Note',
        preview: 'Preview',
        createdAt: DateTime.now(),
      );

      // User assigns explicit category
      final Note userCategorized = initialNote.withUserCategory('Personal');
      expect(userCategorized.category, equals('Personal'));
      expect(userCategorized.categorySource, equals(CategorySource.user));
      expect(userCategorized.isUserCategory, isTrue);

      // Attempting to set AI category does NOT override user category
      final Note aiAttempt = userCategorized.withAiCategory(
        'Automated AI Category',
      );
      expect(aiAttempt.category, equals('Personal'));
      expect(aiAttempt.categorySource, equals(CategorySource.user));

      // Finalizer contract also preserves explicit user category
      const IntegrationNoteCategoryFinalizer finalizer =
          IntegrationNoteCategoryFinalizer();
      final Note finalizedUserNote = await finalizer.finalizeCategory(
        note: userCategorized,
        transcript: 'Full transcript of business meeting',
        suggestedAiCategory: 'Business',
      );
      expect(finalizedUserNote.category, equals('Personal'));
      expect(finalizedUserNote.categorySource, equals(CategorySource.user));

      // If note has NO user category, AI finalization assigns AI category
      final Note uncategorizedNote = initialNote;
      final Note finalizedAiNote = await finalizer.finalizeCategory(
        note: uncategorizedNote,
        transcript: 'Full transcript of brainstorming session',
        suggestedAiCategory: 'Brainstorm',
      );
      expect(finalizedAiNote.category, equals('Brainstorm'));
      expect(finalizedAiNote.categorySource, equals(CategorySource.ai));
      expect(finalizedAiNote.isAiCategory, isTrue);
    });

    test('Account isolation and disappearing category resets to All in LatestNoteCubit', () async {
      final InMemoryNotesRepository repo = InMemoryNotesRepository();
      final DateTime now = DateTime.now();

      await repo.saveNote(
        Note(
          id: 'u1-n1',
          userId: 'user-alpha',
          title: 'Alpha Note',
          preview: 'Preview',
          createdAt: now,
          category: 'Projects',
        ),
      );
      await repo.saveNote(
        Note(
          id: 'u2-n1',
          userId: 'user-beta',
          title: 'Beta Note',
          preview: 'Preview',
          createdAt: now,
          category: 'Finance',
        ),
      );

      final LatestNoteCubit cubit = LatestNoteCubit(repository: repo);

      // 1. Load for user-alpha
      await cubit.load(userId: 'user-alpha');
      expect(cubit.state.categories, equals(['Projects']));
      expect(cubit.state.filteredNotes.length, equals(1));
      expect(cubit.state.filteredNotes.first.id, equals('u1-n1'));

      // Select 'Projects'
      cubit.selectCategory('Projects');
      expect(cubit.state.selectedCategory, equals('Projects'));

      // If a non-existent category is selected or category disappears, reset to All (null)
      cubit.selectCategory('NonExistent');
      expect(cubit.state.selectedCategory, isNull);

      // 2. Switch account to user-beta: categories and notes must isolate cleanly
      await cubit.load(userId: 'user-beta');
      expect(cubit.state.categories, equals(['Finance']));
      expect(cubit.state.filteredNotes.first.id, equals('u2-n1'));
      expect(cubit.state.categories.contains('Projects'), isFalse);

      // 3. Clear on sign-out
      cubit.clear();
      expect(cubit.state, isA<LatestNoteInitial>());
      expect(cubit.state.categories, isEmpty);
      expect(cubit.state.selectedCategory, isNull);
    });

    testWidgets(
      'FeedChannelTabs renders "All" first, user categories, and responds to selection',
      (tester) async {
        String? selected;

        await tester.pumpWidget(
          MaterialApp(
            theme: MaterialThemes.light,
            home: Scaffold(
              body: FeedChannelTabs(
                categories: const ['Ideas', 'Tasks'],
                selectedCategory: null,
                onCategorySelected: (cat) => selected = cat,
              ),
            ),
          ),
        );
        await tester.pump();

        // "All" is rendered first
        expect(find.text('All'), findsOneWidget);
        expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);

        // Categories from notes rendered
        expect(find.text('Ideas'), findsOneWidget);
        expect(find.text('Tasks'), findsOneWidget);

        // Tapping "Ideas" triggers callback
        await tester.tap(find.text('Ideas'));
        await tester.pump();
        expect(selected, equals('Ideas'));
      },
    );

    test('Regression: initial/empty states and clear() initialize note/category lists with non-null empty defaults', () {
      // 1. Default constructors guarantee non-null List<Note> and List<String>
      const LatestNoteInitial initial = LatestNoteInitial();
      expect(initial.notes, isA<List<Note>>());
      expect(initial.filteredNotes, isA<List<Note>>());
      expect(initial.categories, isA<List<String>>());
      expect(initial.notes, isEmpty);
      expect(initial.filteredNotes, isEmpty);
      expect(initial.categories, isEmpty);

      const LatestNoteEmpty empty = LatestNoteEmpty();
      expect(empty.notes, isA<List<Note>>());
      expect(empty.filteredNotes, isA<List<Note>>());
      expect(empty.categories, isA<List<String>>());
      expect(empty.notes, isEmpty);
      expect(empty.filteredNotes, isEmpty);

      const LatestNoteLoading loading = LatestNoteLoading();
      expect(loading.notes, isA<List<Note>>());
      expect(loading.filteredNotes, isA<List<Note>>());
      expect(loading.categories, isA<List<String>>());

      // 2. copyWith preserves non-null defaults even if nullable arguments are passed
      final LatestNoteState copiedInitial = initial.copyWith(
        clearSelectedCategory: true,
      );
      expect(copiedInitial.notes, isA<List<Note>>());
      expect(copiedInitial.filteredNotes, isA<List<Note>>());
      expect(copiedInitial.categories, isA<List<String>>());

      // 3. Cubit clear() and onAccountSwitched() paths guarantee non-null lists
      final LatestNoteCubit cubit = LatestNoteCubit(
        repository: InMemoryNotesRepository(),
      );
      expect(cubit.state.notes, isA<List<Note>>());
      expect(cubit.state.filteredNotes, isA<List<Note>>());
      expect(cubit.state.categories, isA<List<String>>());

      cubit.onAccountSwitched(newUserId: 'other-user');
      expect(cubit.state.notes, isA<List<Note>>());
      expect(cubit.state.filteredNotes, isA<List<Note>>());
      expect(cubit.state.categories, isA<List<String>>());

      cubit.clear();
      expect(cubit.state.notes, isA<List<Note>>());
      expect(cubit.state.filteredNotes, isA<List<Note>>());
      expect(cubit.state.categories, isA<List<String>>());
      expect(cubit.state.notes, isEmpty);
      expect(cubit.state.filteredNotes, isEmpty);
      expect(cubit.state.categories, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 5. DevVersionarteProvider [UNIT]
  // -------------------------------------------------------------------------
  group('DevVersionarteProvider [UNIT]', () {
    // package_info_plus uses a MethodChannel that requires a platform runner.
    // We stub it here so the test host can resolve it.
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/package_info'),
            (MethodCall call) async {
              if (call.method == 'getAll') {
                return <String, dynamic>{
                  'appName': 'Untangle',
                  'packageName': 'app.bunpod',
                  'version': '1.0.0',
                  'buildNumber': '1',
                  'buildSignature': '',
                  'installerStore': null,
                };
              }
              return null;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/package_info'),
            null,
          );
    });

    test(
      'getDistributionManifest returns a manifest with current version as minimum and latest',
      () async {
        const DevVersionarteProvider provider = DevVersionarteProvider();
        final manifest = await provider.getDistributionManifest();

        expect(manifest, isNotNull);
        expect(manifest!.android, isNotNull);
        expect(manifest.iOS, isNotNull);

        // Both platforms should report the same version (running version) so
        // no force-update or optional-update UI is triggered.
        final androidVersion = manifest.android!.version;
        expect(androidVersion.minimum, isNotEmpty);
        expect(androidVersion.latest, isNotEmpty);
        expect(androidVersion.minimum, equals(androidVersion.latest));
      },
    );

    test(
      'getDistributionManifest reports app as active (no maintenance screen)',
      () async {
        const DevVersionarteProvider provider = DevVersionarteProvider();
        final manifest = await provider.getDistributionManifest();
        expect(manifest?.android?.status.active, isTrue);
        expect(manifest?.iOS?.status.active, isTrue);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class MockPlayerHandler extends BaseAudioHandler implements PlayerHandler {
  @override
  Future<void> stop() async {}

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Stream<PositionDiscontinuity> get seeks =>
      const Stream<PositionDiscontinuity>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CancellingSocialSignInService extends SocialSignInService {
  const _CancellingSocialSignInService();

  @override
  Future<SocialSignInResult> signIn(AuthProvider provider) async {
    throw const SocialSignInCancelled();
  }
}

class _FailingSocialSignInService extends SocialSignInService {
  const _FailingSocialSignInService();

  @override
  Future<SocialSignInResult> signIn(AuthProvider provider) async {
    throw Exception('Authentication provider error');
  }
}

class _SessionlessSocialSignInService extends SocialSignInService {
  const _SessionlessSocialSignInService();

  @override
  Future<SocialSignInResult> signIn(AuthProvider provider) async {
    return SocialSignInResult(
      provider: provider,
      idToken: 'sample-id-token',
      uid: 'sample-uid',
      // No accessToken or refreshToken
    );
  }
}

class _FakeSupabaseUser {
  const _FakeSupabaseUser({
    required this.id,
    required this.email,
    this.appMetadata,
    this.userMetadata,
    this.createdAt,
  });

  final String id;
  final String email;
  final Map<String, dynamic>? appMetadata;
  final Map<String, dynamic>? userMetadata;
  final String? createdAt;
}

// ---------------------------------------------------------------------------
// MANUAL VERIFICATION CHECKLIST
// (Things this test suite does NOT cover — must be verified by running the app)
//
// [ ] Signed-out startup: launch without any cached session; app opens WelcomePage.
// [ ] Restored session: sign in, force-quit, re-launch; app opens FeedPage without
//     re-authenticating.
// [ ] Placeholder config: assets/config/supabase_config.json with placeholder
//     values → app shows _ConfigErrorApp setup screen, not a crash.
// [ ] Missing config: empty SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY → same.
// [ ] Google sign-in (Android): requires real OAuth client IDs and a signed APK;
//     see the Google/Supabase manual setup steps in the stop-report.
// [ ] Token refresh: let the session age past 1 hour; confirm the onAuthStateChange
//     tokenRefreshed handler fires and cacheTokens() updates secure storage.
// [ ] Sign-out routing: sign out from MenuPage; app navigates to WelcomePage(farewell: logout)
//     with no route loop.
// [ ] Account change isolation: sign out, sign in as a different user; confirm
//     FeedCubit, SubscriptionsCubit and UserCubit start fresh.
// ---------------------------------------------------------------------------
