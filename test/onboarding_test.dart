import 'dart:async';

import 'package:ai_chatbot/screens/app_splash_screen.dart';
import 'package:ai_chatbot/screens/onboarding_screen.dart';
import 'package:ai_chatbot/services/onboarding_store.dart';
import 'package:ai_chatbot/theme/app_colors.dart';
import 'package:ai_chatbot/theme/app_theme.dart';
import 'package:ai_chatbot/theme/app_tokens.dart';
import 'package:ai_chatbot/widgets/mind_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_onboarding_store.dart';
import 'support/visual_capture.dart';

Widget home(BuildContext context) => const Scaffold(body: Text('Home destination'));

Future<void> pumpEntry(WidgetTester tester, Widget screen,
    {Size size = const Size(393, 852), double scale = 1, bool reduced = false,
     EdgeInsets padding = EdgeInsets.zero, EdgeInsets keyboard = EdgeInsets.zero,
     NavigatorObserver? observer}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.legacy, home: screen,
    navigatorObservers: [if (observer != null) observer],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale),
        disableAnimations: reduced, padding: padding, viewPadding: padding, viewInsets: keyboard),
      child: child!),
  ));
}

Future<void> advance(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('onboarding-next')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadPreviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('onboarding completion persists across store instances without touching other preferences', () async {
    SharedPreferences.setMockInitialValues({'unrelated_preference': 'preserved'});
    const first = PreferencesOnboardingStore();
    expect(await first.isComplete(), isFalse);
    await first.markComplete();
    expect(await const PreferencesOnboardingStore().isComplete(), isTrue);
    expect((await SharedPreferences.getInstance()).getString('unrelated_preference'), 'preserved');
  });

  test('Android navigation appearance uses a high-contrast fallback on older platforms', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppTheme.appearanceChannel, (call) async => false);
    await AppTheme.configurePlatformAppearance();
    expect(AppTheme.lightSystemUi.systemNavigationBarColor, AppColors.ink);
    expect(AppTheme.lightSystemUi.systemNavigationBarIconBrightness, Brightness.light);
    messenger.setMockMethodCallHandler(AppTheme.appearanceChannel, (call) async => true);
    await AppTheme.configurePlatformAppearance();
    expect(AppTheme.lightSystemUi.systemNavigationBarColor, AppColors.canvas);
    expect(AppTheme.lightSystemUi.systemNavigationBarIconBrightness, Brightness.dark);
    messenger.setMockMethodCallHandler(AppTheme.appearanceChannel, null);
  });

  testWidgets('first launch opens onboarding; completion replaces the root exactly once', (tester) async {
    final store = FakeOnboardingStore();
    final observer = RouteCounter();
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false, store: store, homeBuilder: home), observer: observer);
    await tester.pumpAndSettle();
    expect(find.text('A clearer mind,\none chat away.'), findsOneWidget);
    await advance(tester);
    expect(find.text('Find the words.\nMake them yours.'), findsOneWidget);
    await advance(tester);
    expect(find.text('Good thoughts.\nWorth keeping.'), findsOneWidget);
    await advance(tester);
    expect(store.complete, isTrue);
    expect(store.writes, 1);
    expect(find.text('Home destination'), findsOneWidget);
    expect(observer.active, 1);
    expect(Navigator.of(tester.element(find.text('Home destination'))).canPop(), isFalse);
  });

  testWidgets('returning guest skips onboarding without a mandatory splash timer', (tester) async {
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false,
      store: FakeOnboardingStore(complete: true), homeBuilder: home));
    await tester.pump();
    await tester.pump();
    await tester.pump(AppMotion.route + const Duration(milliseconds: 10));
    expect(find.text('Home destination'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('signed-in returning user skips preference reading and records completion', (tester) async {
    final store = FakeOnboardingStore(failRead: true);
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: true, store: store, homeBuilder: home));
    await tester.pumpAndSettle();
    expect(store.reads, 0);
    expect(store.writes, 1);
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('startup rechecks identity after an asynchronous preference read', (tester) async {
    final store = FakeOnboardingStore()..readGate = Completer<bool>();
    var signedIn = false;
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false, isSignedIn: () => signedIn,
      store: store, homeBuilder: home));
    await tester.pump(const Duration(seconds: 2));
    signedIn = true;
    store.readGate!.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
    expect(store.complete, isTrue);
  });

  testWidgets('slow preference resolution schedules a route after the reveal has finished', (tester) async {
    final store = FakeOnboardingStore()..readGate = Completer<bool>();
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false, store: store, homeBuilder: home));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(AppSplashScreen), findsOneWidget);
    store.readGate!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('Skip persists completion and does not create an account or open auth', (tester) async {
    final store = FakeOnboardingStore();
    await pumpEntry(tester, OnboardingScreen(store: store, homeBuilder: home));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(store.complete, isTrue);
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('Back button and Android back navigate pages before leaving the intro', (tester) async {
    await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home));
    await tester.pumpAndSettle();
    await advance(tester);
    await tester.tap(find.byKey(const Key('onboarding-back')));
    await tester.pumpAndSettle();
    expect(find.text('A clearer mind,\none chat away.'), findsOneWidget);
    await advance(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('A clearer mind,\none chat away.'), findsOneWidget);
  });

  testWidgets('read failure keeps onboarding usable', (tester) async {
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false,
      store: FakeOnboardingStore(failRead: true), homeBuilder: home));
    await tester.pumpAndSettle();
    expect(find.text('Your intro preference couldn’t be read. You can still continue.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('write failure is explicit and offers retry or continuation without saving', (tester) async {
    final store = FakeOnboardingStore(failWrite: true);
    await pumpEntry(tester, OnboardingScreen(store: store, homeBuilder: home));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(store.complete, isFalse);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Couldn’t save your intro preference. Try again, or continue for now.'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue for now'));
    await tester.tap(find.text('Continue for now'));
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
    expect(store.complete, isFalse);
  });

  testWidgets('repeated completion taps cannot create duplicate routes or preference writes', (tester) async {
    final store = FakeOnboardingStore()..writeGate = Completer<void>();
    final observer = RouteCounter();
    await pumpEntry(tester, OnboardingScreen(store: store, homeBuilder: home), observer: observer);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    expect(store.writes, 1);
    store.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(observer.active, 1);
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('splash can dispose during preference read and animation', (tester) async {
    final store = FakeOnboardingStore()..readGate = Completer<bool>();
    await pumpEntry(tester, AppSplashScreen(isLoggedIn: false, store: store, homeBuilder: home));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(const SizedBox.shrink());
    store.readGate!.complete(false);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('onboarding can dispose during page motion and preference saving', (tester) async {
    await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home));
    await tester.pump();
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    final store = FakeOnboardingStore()..writeGate = Completer<void>();
    await pumpEntry(tester, OnboardingScreen(store: store, homeBuilder: home));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    store.writeGate!.complete();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion leaves no decorative ticker and pages change without animated scrolling', (tester) async {
    await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home), reduced: true);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pump();
    expect(find.text('Find the words.\nMake them yours.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final size in [const Size(360, 640), const Size(393, 852), const Size(430, 932),
                     const Size(852, 393), const Size(800, 1100)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('all pages fit or scroll without overflow at ${size.width}x${size.height}, text $scale', (tester) async {
        await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home),
            size: size, scale: scale, reduced: true,
            padding: const EdgeInsets.only(top: 24, bottom: 24));
        await tester.pumpAndSettle();
        for (var page = 0; page < 3; page++) {
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('onboarding-next')).hitTestable(), findsOneWidget);
          if (page < 2) await advance(tester);
        }
      });
    }
  }

  testWidgets('keyboard insets and very short available height use a scroll fallback', (tester) async {
    await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home),
      size: const Size(360, 640), keyboard: const EdgeInsets.only(bottom: 360),
      padding: const EdgeInsets.only(top: 24, bottom: 24), reduced: true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('page labels, labeled controls, contrast and Android touch targets pass Flutter guidelines', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home), reduced: true);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Introduction, page 1 of 3'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await advance(tester);
      expect(find.bySemanticsLabel('Introduction, page 2 of 3'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await advance(tester);
      expect(find.bySemanticsLabel('Introduction, page 3 of 3'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('keyboard focus and Enter activate a labeled standard button', (tester) async {
    final store = FakeOnboardingStore();
    await pumpEntry(tester, OnboardingScreen(store: store, homeBuilder: home), reduced: true);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(store.complete, isTrue);
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('entry theme and system bars use light surfaces without changing the legacy palette', (tester) async {
    await pumpEntry(tester, OnboardingScreen(store: FakeOnboardingStore(), homeBuilder: home), reduced: true);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(MindWordmark));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(AppTheme.legacy.brightness, Brightness.dark);
    final regions = tester.widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>));
    expect(regions.any((region) => region.value.statusBarIconBrightness == Brightness.dark), isTrue);
    expect(AppColors.bg, const Color(0xFF08001A));
  });
}

class RouteCounter extends NavigatorObserver {
  int active = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) { active++; }
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {}
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) { active--; }
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) { active--; }
}
