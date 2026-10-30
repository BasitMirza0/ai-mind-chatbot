// Compatibility exports keep existing chat/auth/voice imports stable.
export '../widgets/bot_logo.dart' show BotLogo;
export 'onboarding_screen.dart' show OnboardingScreen;

import 'onboarding_screen.dart';

typedef SplashScreen = OnboardingScreen;
