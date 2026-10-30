#!/bin/sh
# Run after the local Dart CLI runtime issue is resolved. Only Phase 2A Dart files.
set -eu
cd "$(dirname "$0")/.."
dart format \
  lib/main.dart \
  lib/theme/app_colors.dart \
  lib/theme/app_tokens.dart \
  lib/theme/app_theme.dart \
  lib/screens/app_splash_screen.dart \
  lib/screens/splash_screen.dart \
  lib/screens/onboarding_screen.dart \
  lib/services/onboarding_store.dart \
  lib/widgets/bot_logo.dart \
  lib/widgets/entry_components.dart \
  lib/widgets/mind_mark.dart \
  lib/widgets/onboarding_illustration.dart \
  test/onboarding_test.dart \
  test/phase2a_visual_test.dart \
  test/widget_test.dart \
  test/support/visual_capture.dart \
  test/support/fake_onboarding_store.dart
