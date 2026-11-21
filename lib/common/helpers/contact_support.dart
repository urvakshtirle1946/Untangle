import 'package:bunpod/features/menu/pages/feedback_draft_page.dart';
import 'package:flutter/material.dart';

abstract final class ContactSupport {
  static Future<void> suggestFeature(BuildContext context) =>
      Navigator.of(context).push<void>(
        FeedbackDraftPage.featureSuggestionRoute(),
      );

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push<void>(
        FeedbackDraftPage.issueReportRoute(),
      );
}
