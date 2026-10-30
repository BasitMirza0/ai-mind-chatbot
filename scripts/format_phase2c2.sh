#!/bin/sh
# Scoped formatter for Phase 2C.2; run from the project root.
set -eu
dart format \
  lib/controllers/sidebar_controller.dart \
  lib/services/sidebar_history_source.dart \
  lib/services/conversation_repository.dart \
  lib/widgets/chat_sidebar.dart \
  lib/screens/chat_screen.dart \
  test/sidebar_controller_test.dart \
  test/sidebar_history_source_test.dart \
  test/sidebar_widget_test.dart \
  test/sidebar_visual_test.dart \
  test/support/fake_sidebar_source.dart \
  test/support/fake_chat_dependencies.dart \
  test/phase2c1_regression_test.dart \
  test/home_chat_widget_test.dart
