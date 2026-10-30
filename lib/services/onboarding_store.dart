import 'package:shared_preferences/shared_preferences.dart';

abstract interface class OnboardingStore {
  Future<bool> isComplete();
  Future<void> markComplete();
}

/// One installation-scoped preference. No account, token or conversation data.
class PreferencesOnboardingStore implements OnboardingStore {
  static const completionKey = 'ai_mind.onboarding_complete.v1';
  static const _storageTimeout = Duration(seconds: 3);
  const PreferencesOnboardingStore();

  @override
  Future<bool> isComplete() async =>
      (await SharedPreferences.getInstance().timeout(_storageTimeout)).getBool(completionKey) ?? false;

  @override
  Future<void> markComplete() async {
    final preferences = await SharedPreferences.getInstance().timeout(_storageTimeout);
    final saved = await preferences.setBool(completionKey, true).timeout(_storageTimeout);
    if (!saved) throw StateError('Onboarding preference was not saved');
  }
}
