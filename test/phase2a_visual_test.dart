import 'dart:async';

import 'package:ai_chatbot/screens/app_splash_screen.dart';
import 'package:ai_chatbot/screens/onboarding_screen.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_onboarding_store.dart';
import 'support/visual_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadPreviewFonts);

  testWidgets('capture actual Flutter entry screens for private local review', (tester) async {
    final boundary = GlobalKey();
    final sizes = [const Size(360, 800), const Size(393, 852), const Size(430, 932), const Size(852, 393)];
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    Widget app(Widget screen, {double scale = 1}) => RepaintBoundary(key: boundary,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: AppTheme.legacy,
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 24, bottom: 24),
          viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
          textScaler: TextScaler.linear(scale), disableAnimations: true,
        ), child: child!), home: screen));
    for (final size in sizes) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(app(OnboardingScreen(key: ValueKey(size), store: FakeOnboardingStore())));
      await tester.runAsync(() => precacheImage(const AssetImage('assets/images/robot.png'), boundary.currentContext!));
      await tester.pumpAndSettle();
      for (var page = 0; page < 3; page++) {
        await capturePreview(tester, boundary, 'after_onboarding_${page + 1}_${size.width.toInt()}x${size.height.toInt()}');
        if (page < 2) {
          await tester.tap(find.byKey(const Key('onboarding-next')));
          await tester.pumpAndSettle();
        }
      }
    }
    tester.view.physicalSize = const Size(393, 852);
    await tester.pumpWidget(app(OnboardingScreen(key: const Key('large-text'), store: FakeOnboardingStore()), scale: 2));
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, 'after_onboarding_393_text200');
    await tester.ensureVisible(find.text('A clearer mind,\none chat away.'));
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, 'after_onboarding_393_text200_scrolled');
    final pending = FakeOnboardingStore()..readGate = Completer<bool>();
    await tester.pumpWidget(app(AppSplashScreen(isLoggedIn: false, store: pending)));
    await tester.pumpAndSettle();
    await capturePreview(tester, boundary, 'after_splash_393');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.readGate!.complete(false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
