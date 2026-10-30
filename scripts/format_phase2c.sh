#!/bin/sh
# Run in the normal local terminal if the sandbox Dart VM fails before startup.
set -eu
cd "$(dirname "$0")/.."
dart format \
  lib/controllers/chat_controller.dart \
  lib/controllers/voice_controller.dart \
  lib/screens/chat_history_screen.dart \
  lib/screens/chat_screen.dart \
  lib/screens/home_screen.dart \
  lib/screens/login_screen.dart \
  lib/screens/signup_screen.dart \
  lib/screens/voice_screen.dart \
  lib/services/app_session.dart \
  lib/services/auth_service.dart \
  lib/services/conversation_repository.dart \
  lib/services/speech_coordinator.dart \
  lib/services/speech_output.dart \
  lib/widgets/auth_form.dart \
  lib/widgets/profile_avatar.dart \
  lib/widgets/voice_visualization.dart \
  test/auth_flow_test.dart \
  test/conversation_repository_test.dart \
  test/phase2c_functionality_test.dart \
  test/phase2c_screens_test.dart \
  test/phase2c_visual_test.dart \
  test/speech_output_test.dart \
  test/support/fake_auth.dart \
  test/support/fake_chat_dependencies.dart \
  test/support/fake_voice_dependencies.dart \
  test/voice_controller_test.dart
