import 'package:flutter/foundation.dart';

/// Development switches are compile-time constants and disabled outside debug.
abstract final class AppDebugOptions {
  static const forceOnboarding = kDebugMode &&
      bool.fromEnvironment('AI_MIND_FORCE_ONBOARDING', defaultValue: false);
}
