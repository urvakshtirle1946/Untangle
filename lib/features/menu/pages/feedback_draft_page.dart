import 'package:bunpod/common/values/app_values.dart';
import 'package:bunpod/features/profile/cubits/user_cubit.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

typedef MailCanLaunch = Future<bool> Function(Uri uri);
typedef MailLaunch = Future<bool> Function(Uri uri);
typedef AppVersionLoader = Future<String> Function();

final GetIt _locator = GetIt.instance;

class FeedbackDraftPage extends StatefulWidget {
  const FeedbackDraftPage({
    super.key,
    required this.title,
    required this.subject,
    this.accountId,
    this.versionLoader = _loadAppVersion,
    this.canLaunchMail = _canLaunchMail,
    this.launchMail = _launchMail,
  });

  static const String recipient = AppValues.supportEmail;

  final String title;
  final String subject;
  final String? accountId;
  final AppVersionLoader versionLoader;
  final MailCanLaunch canLaunchMail;
  final MailLaunch launchMail;

  static Uri buildMailtoUri({
    required String subject,
    required String message,
    required String appVersion,
    String? accountId,
  }) {
    final List<String> footer = <String>[
      if (accountId?.trim().isNotEmpty == true)
        'Account ID: ${accountId!.trim()}',
      'App version: $appVersion',
    ];
    return Uri(
      scheme: 'mailto',
      path: recipient,
      queryParameters: <String, String>{
        'subject': subject,
        'body': '$message\n\n${footer.join('\n')}',
      },
    );
  }

  static Route<void> featureSuggestionRoute() => MaterialPageRoute<void>(
    builder: (_) => const FeedbackDraftPage(
      title: 'Suggest a feature',
      subject: 'Untangle feature suggestion',
    ),
  );

  static Route<void> issueReportRoute() => MaterialPageRoute<void>(
    builder: (_) => const FeedbackDraftPage(
      title: 'Report an issue',
      subject: 'Untangle issue report',
    ),
  );

  @override
  State<FeedbackDraftPage> createState() => _FeedbackDraftPageState();
}

class _FeedbackDraftPageState extends State<FeedbackDraftPage> {
  final TextEditingController _messageController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String? get _accountId {
    final String? provided = widget.accountId;
    if (provided != null) return provided;
    if (!_locator.isRegistered<UserCubit>()) return null;
    final String? id = _locator<UserCubit>().state?.id;
    return id?.trim().isNotEmpty == true ? id : null;
  }

  Future<void> _send() async {
    if (_sending) return;
    final String message = _messageController.text;
    if (message.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a message first.')),
      );
      return;
    }

    setState(() => _sending = true);
    try {
      late final String version;
      try {
        version = await widget.versionLoader();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not prepare the email draft. Please retry.'),
            ),
          );
        }
        return;
      }
      final Uri uri = FeedbackDraftPage.buildMailtoUri(
        subject: widget.subject,
        message: message,
        appVersion: version,
        accountId: _accountId,
      );
      final bool available = await widget.canLaunchMail(uri);
      final bool launched = available && await widget.launchMail(uri);
      if (!launched && mounted) await _showMailUnavailable();
    } catch (_) {
      if (mounted) await _showMailUnavailable();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showMailUnavailable() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('No mail app available'),
        content: Text(
          'Untangle could not open a mail app. You can copy '
          '${FeedbackDraftPage.recipient} and send your message another way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(text: FeedbackDraftPage.recipient),
              );
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Email address copied.')),
                );
              }
            },
            child: const Text('Copy address'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text(
                'Send opens your mail app with a draft. When signed in, '
                'the draft includes your account ID and app version.',
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  key: const Key('feedback-message'),
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Write your message…',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('feedback-send'),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> _loadAppVersion() async =>
    (await PackageInfo.fromPlatform()).version;

Future<bool> _canLaunchMail(Uri uri) => canLaunchUrl(uri);

Future<bool> _launchMail(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
