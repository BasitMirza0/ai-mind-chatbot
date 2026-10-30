#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
dart format \
  lib/screens/chat_screen.dart \
  lib/widgets/auth_form.dart \
  lib/widgets/voice_visualization.dart \
  test/home_chat_widget_test.dart \
  test/phase2c1_regression_test.dart \
  test/phase2c1_visual_test.dart \
  test/phase2c_functionality_test.dart \
  test/phase2c_screens_test.dart \
  test/phase2c_visual_test.dart
