import 'package:ai_chatbot/config/app_debug_options.dart';
import 'package:ai_chatbot/screens/app_splash_screen.dart';
import 'package:ai_chatbot/screens/onboarding_screen.dart';
import 'package:ai_chatbot/services/onboarding_store.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_onboarding_store.dart';

Widget _home(BuildContext context) => const Scaffold(body: Text('Existing Home'));

class _Routes extends NavigatorObserver {
  int active = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) { active++; }
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) { active--; }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) { active--; }
}

Future<void> _launch(WidgetTester tester, OnboardingStore store,
    {bool signedIn = true, _Routes? routes}) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.legacy,
    navigatorObservers: [if (routes != null) routes],
    home: AppSplashScreen(isLoggedIn: signedIn, isSignedIn: () => signedIn,
      store: store, homeBuilder: _home)));
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, {required bool skip}) async {
  if (skip) {
    await tester.tap(find.byKey(const Key('onboarding-skip')));
  } else {
    expect(find.text('A clearer mind,\none chat away.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Find the words.\nMake them yours.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Good thoughts.\nWorth keeping.'), findsOneWidget);
    await tester.tap(find.text('Get started'));
  }
  await tester.pumpAndSettle();
  expect(find.text('Existing Home'), findsOneWidget);
  expect(Navigator.of(tester.element(find.text('Existing Home'))).canPop(), isFalse);
}

Map<String, Object?> _values(SharedPreferences preferences) => {
  for (final key in preferences.getKeys()) key: preferences.get(key),
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Run this file both normally and with the actual compile-time define enabled.
  // There is no runtime testing override that could bypass the release guard.
  if (AppDebugOptions.forceOnboarding) {
    for (final completion in <bool?>[null, false, true]) {
      for (final skip in [false, true]) {
        testWidgets('debug preview preserves saved state $completion after ${skip ? 'Skip' : 'Get started'}', (tester) async {
          SharedPreferences.setMockInitialValues({
            if (completion != null) PreferencesOnboardingStore.completionKey: completion,
            'unrelated_preference': 'keep-me',
          });
          final preferences = await SharedPreferences.getInstance();
          final before = _values(preferences);
          final routes = _Routes();
          await _launch(tester, const PreferencesOnboardingStore(), routes: routes);
          expect(find.byType(OnboardingScreen), findsOneWidget);
          // Startup must not run the signed-in user's normal completion write.
          expect(_values(preferences), before);
          await _finish(tester, skip: skip);
          expect(_values(preferences), before);
          expect(routes.active, 1);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('preview does not read or write the completion store, even if storage fails', (tester) async {
      final store = FakeOnboardingStore(failRead: true, failWrite: true);
      await _launch(tester, store);
      expect(store.reads, 0);
      expect(store.writes, 0);
      final screen = tester.widget<OnboardingScreen>(find.byType(OnboardingScreen));
      expect(screen.preview, isTrue);
      await _finish(tester, skip: false);
      expect(store.reads, 0);
      expect(store.writes, 0);
      expect(store.complete, isFalse);
    });

    testWidgets('guest preview exits to the existing guest Home without marking completion', (tester) async {
      final store = FakeOnboardingStore();
      await _launch(tester, store, signedIn: false);
      await _finish(tester, skip: true);
      expect(store.writes, 0);
      expect(store.complete, isFalse);
    });

    testWidgets('rapid preview exit cannot add duplicate routes', (tester) async {
      final store = FakeOnboardingStore(complete: true);
      final routes = _Routes();
      await _launch(tester, store, routes: routes);
      final button = tester.widget<TextButton>(find.byKey(const Key('onboarding-skip')));
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Existing Home'), findsOneWidget);
      expect(routes.active, 1);
      expect(store.writes, 0);
    });
  } else {
    testWidgets('normal returning guest still skips completed onboarding', (tester) async {
      final store = FakeOnboardingStore(complete: true);
      await _launch(tester, store, signedIn: false);
      expect(find.text('Existing Home'), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(store.writes, 0);
    });

    testWidgets('normal signed-in startup retains its existing completion behavior', (tester) async {
      final store = FakeOnboardingStore();
      await _launch(tester, store);
      expect(find.text('Existing Home'), findsOneWidget);
      expect(store.reads, 0);
      expect(store.writes, 1);
      expect(store.complete, isTrue);
    });

    testWidgets('normal first launch still persists completion and preserves unrelated preferences', (tester) async {
      SharedPreferences.setMockInitialValues({'unrelated_preference': 'keep-me'});
      await _launch(tester, const PreferencesOnboardingStore(), signedIn: false);
      await _finish(tester, skip: false);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool(PreferencesOnboardingStore.completionKey), isTrue);
      expect(preferences.getString('unrelated_preference'), 'keep-me');
    });

    testWidgets('a preview parameter alone cannot bypass normal completion behavior', (tester) async {
      final store = FakeOnboardingStore();
      await tester.pumpWidget(MaterialApp(theme: AppTheme.legacy,
        home: OnboardingScreen(store: store, homeBuilder: _home, preview: true)));
      await tester.pumpAndSettle();
      await _finish(tester, skip: true);
      expect(store.writes, 1);
      expect(store.complete, isTrue);
    });
  }
}
