import 'package:bunpod/features/menu/pages/feedback_draft_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'mailto draft includes recipient, subject, message, and account footer',
    () {
      final Uri uri = FeedbackDraftPage.buildMailtoUri(
        subject: 'Untangle feature suggestion',
        message: 'Please add tags & folders.',
        appVersion: '1.2.3',
        accountId: 'user-42',
      );

      expect(uri.scheme, 'mailto');
      expect(uri.path, 'urvakshtirle@gmail.com');
      expect(uri.queryParameters['subject'], 'Untangle feature suggestion');
      expect(
        uri.queryParameters['body'],
        'Please add tags & folders.\n\nAccount ID: user-42\nApp version: 1.2.3',
      );
    },
  );

  test('mailto draft omits account ID when no user is signed in', () {
    final Uri uri = FeedbackDraftPage.buildMailtoUri(
      subject: 'Untangle issue report',
      message: 'A report',
      appVersion: '1.2.3',
    );

    expect(uri.queryParameters['body'], 'A report\n\nApp version: 1.2.3');
  });

  testWidgets('empty feedback shows an error without opening mail', (
    tester,
  ) async {
    bool launched = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FeedbackDraftPage(
          title: 'Suggest a feature',
          subject: 'Untangle feature suggestion',
          accountId: 'user-42',
          versionLoader: () async => '1.2.3',
          canLaunchMail: (_) async => true,
          launchMail: (_) async {
            launched = true;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pump();

    expect(find.text('Enter a message first.'), findsOneWidget);
    expect(launched, isFalse);
  });

  testWidgets('Send launches the expected encoded mailto draft', (
    tester,
  ) async {
    Uri? launchedUri;
    await tester.pumpWidget(
      MaterialApp(
        home: FeedbackDraftPage(
          title: 'Report an issue',
          subject: 'Untangle issue report',
          accountId: 'account-7',
          versionLoader: () async => '2.0.1',
          canLaunchMail: (_) async => true,
          launchMail: (Uri uri) async {
            launchedUri = uri;
            return true;
          },
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('feedback-message')),
      'Crashes on save & retry.',
    );
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pump();
    await tester.pump();

    expect(launchedUri, isNotNull);
    expect(launchedUri!.scheme, 'mailto');
    expect(launchedUri!.path, 'urvakshtirle@gmail.com');
    expect(launchedUri!.queryParameters['subject'], 'Untangle issue report');
    expect(
      launchedUri!.queryParameters['body'],
      'Crashes on save & retry.\n\nAccount ID: account-7\nApp version: 2.0.1',
    );
  });

  testWidgets('unavailable mail app offers to copy the support address', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FeedbackDraftPage(
          title: 'Report an issue',
          subject: 'Untangle issue report',
          versionLoader: () async => '2.0.1',
          canLaunchMail: (_) async => false,
          launchMail: (_) async => false,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('feedback-message')),
      'The app could not open my email app.',
    );
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('No mail app available'), findsOneWidget);
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.textContaining('urvakshtirle@gmail.com'), findsOneWidget);
  });
}
