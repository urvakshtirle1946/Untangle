# Changes from BunPod

Untangle is based on BunPod by Kamran Bekirov (https://github.com/kamranbekirovyz/bunpod),
used under the Apache License 2.0. This file states the changes made by Urvaksh Tirle
relative to BunPod revision 835e843.

## Main areas changed

- Notes speech-to-text: Sherpa ONNX streaming adapter, speech_to_text adapter and the
  shared adapter interface (lib/features/notes/stt/).
- Conversation: live recognition with endpoint settings, automatic restarts, and an
  error message when recognition cannot continue.
- Record: shared 16 kHz mono capture feeding a WAV file and live transcription.
- Notes: save payload fixes, a Finish note save path for the Type tab, a latest note
  card, and an animated orb widget.
- Player: player page, controls, screen layout and audio player handlers.
- Profile and subscriptions: user model and cubit updates, subscriptions cubit update.
- Settings: feedback and issue reports open an email draft.
- App shell: main.dart, pubspec.yaml and pubspec.lock, version-check pages, and a
  local run script (scripts/flutter-run-local.ps1).
- Supabase: configuration and an AI chat function (supabase/functions/nvidia-chat).
- Tests: new and updated tests under test/.
- User-facing app name changed to Untangle.

## Files changed since BunPod revision 835e843
(A = added, M = modified, D = deleted, R = renamed)

A	.env.example
D	.github/assets/cover.png
M	.gitignore
D	.vscode/launch.json
M	README.md
M	analysis_options.yaml
M	android/app/src/main/AndroidManifest.xml
M	android/gradle.properties
A	assets/config/supabase_config.json
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/MODEL_LICENSE.txt
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/bpe.model
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx
A	assets/models/sherpa_onnx_streaming_zipformer_en_int8/tokens.txt
M	ios/Runner/Info.plist
M	lib/app.dart
M	lib/bunpod.dart
M	lib/common/helpers/contact_support.dart
M	lib/common/helpers/locator.dart
M	lib/common/helpers/sign_out.dart
M	lib/common/values/app_config.dart
M	lib/common/values/app_values.dart
D	lib/common/values/firebase_config.dart
A	lib/common/values/supabase_config.dart
M	lib/common/values/values.dart
M	lib/features/auth/cubits/logout_cubit.dart
M	lib/features/auth/cubits/social_sign_in_cubit.dart
M	lib/features/auth/data_sources/auth_remote_data.dart
M	lib/features/auth/models/social_sign_in_result.dart
M	lib/features/auth/services/mock_social_sign_in_service.dart
M	lib/features/auth/services/social_sign_in_service.dart
M	lib/features/auth/widgets/social_sign_in_button.dart
M	lib/features/feed/cubits/feed_cubit.dart
M	lib/features/feed/pages/feed_page.dart
M	lib/features/feed/widgets/feed_app_bar.dart
M	lib/features/feed/widgets/feed_channel_tabs.dart
A	lib/features/notes/cubits/latest_note_cubit.dart
A	lib/features/notes/cubits/note_player_cubit.dart
A	lib/features/notes/models/note.dart
A	lib/features/notes/models/voice_note_state.dart
A	lib/features/notes/notes.dart
A	lib/features/notes/pages/create_note_placeholder_page.dart
A	lib/features/notes/pages/note_audio_page.dart
A	lib/features/notes/pages/note_detail_page.dart
A	lib/features/notes/pages/note_search_page.dart
A	lib/features/notes/services/conversation_ai_client.dart
A	lib/features/notes/services/note_category_finalizer.dart
A	lib/features/notes/services/note_summary_client.dart
A	lib/features/notes/services/notes_repository.dart
A	lib/features/notes/services/voice_note_audio.dart
A	lib/features/notes/stt/native_stt_adapter.dart
A	lib/features/notes/stt/sherpa_streaming_stt_adapter.dart
A	lib/features/notes/stt/speech_to_text_adapter.dart
A	lib/features/notes/stt/stt.dart
A	lib/features/notes/stt/stt_adapter.dart
A	lib/features/notes/widgets/latest_note_card.dart
A	lib/features/notes/widgets/painterly_orb.dart
M	lib/features/player/pages/player_page.dart
A	lib/features/player/services/note_audio_player_handler.dart
M	lib/features/player/services/player_handler.dart
M	lib/features/player/widgets/player_controls.dart
A	lib/features/player/widgets/player_screen_layout.dart
M	lib/features/profile/cubits/user_cubit.dart
M	lib/features/profile/models/user.dart
M	lib/features/subscriptions/cubits/subscriptions_cubit.dart
M	lib/features/versionarte/pages/app_unavailable_page.dart
M	lib/features/versionarte/pages/force_update_page.dart
A	lib/features/versionarte/providers/dev_versionarte_provider.dart
M	lib/features/versionarte/providers/providers.dart
M	lib/features/versionarte/widgets/update_available_notice.dart
M	lib/main.dart
M	pubspec.lock
M	pubspec.yaml
A	scripts/flutter-run-local.ps1
A	supabase/config.toml
A	supabase/functions/nvidia-chat/index.ts
A	test/features/auth/auth_migration_test.dart
A	test/features/notes/conversation_ai_test.dart
A	test/features/notes/create_note_screen_test.dart
A	test/features/notes/note_audio_page_test.dart
A	test/features/notes/note_category_color_test.dart
A	test/features/notes/note_detail_page_test.dart
A	test/features/notes/note_save_flow_test.dart
A	test/features/notes/note_search_test.dart
A	test/features/notes/note_summary_client_test.dart
A	test/features/notes/notes_repository_record_payload_test.dart
A	test/features/notes/record_stt_test.dart
A	test/features/notes/voice_creation_test.dart
A	test/features/notes/voice_note_audio_flow_test.dart
A	test/features/player/player_screen_layout_test.dart
