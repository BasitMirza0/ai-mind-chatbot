#!/bin/sh
# Scoped formatter; use locally if the sandboxed Dart VM crashes before startup.
set -eu
cd "$(dirname "$0")/.."
dart format \
  lib/models/conversation.dart \
  lib/controllers/chat_controller.dart \
  lib/services/app_session.dart \
  lib/services/conversation_repository.dart \
  lib/screens/home_screen.dart \
  lib/screens/chat_screen.dart \
  lib/widgets/conversation_components.dart \
  lib/widgets/chat_message_card.dart \
  test/chat_controller_test.dart \
  test/conversation_repository_test.dart \
  test/home_chat_widget_test.dart \
  test/phase2b_visual_test.dart \
  test/support/fake_chat_dependencies.dart
