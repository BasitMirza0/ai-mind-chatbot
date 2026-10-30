import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_debug_options.dart';
import '../services/onboarding_store.dart';
import '../theme/app_tokens.dart';
import '../widgets/entry_components.dart';
import '../widgets/mind_mark.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

class AppSplashScreen extends StatefulWidget {
  final bool isLoggedIn;
  final ValueGetter<bool>? isSignedIn;
  final OnboardingStore store;
  final WidgetBuilder? homeBuilder;
  const AppSplashScreen({super.key, required this.isLoggedIn, this.isSignedIn,
    this.store = const PreferencesOnboardingStore(), this.homeBuilder});

  @override
  State<AppSplashScreen> createState() => _AppSplashScreenState();
}

class _AppSplashScreenState extends State<AppSplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(vsync: this, duration: AppMotion.entrance);
  bool _started = false;
  bool _leaving = false;

  bool get _signedIn => widget.isSignedIn?.call() ?? widget.isLoggedIn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _reveal.stop();
      _reveal.value = 1;
    } else if (!_started) {
      _reveal.forward();
    }
    if (!_started) {
      _started = true;
      unawaited(_resolveDestination());
    }
  }

  Future<void> _rememberReturningUser() async {
    try { await widget.store.markComplete(); } catch (_) { /* Do not block a signed-in returning user. */ }
  }

  Future<void> _resolveDestination() async {
    final preview = AppDebugOptions.forceOnboarding;
    var complete = false;
    var readFailed = false;
    var returning = false;
    if (!preview) {
      final initiallySignedIn = _signedIn;
      if (initiallySignedIn) {
        unawaited(_rememberReturningUser());
      } else {
        try { complete = await widget.store.isComplete(); } catch (_) { readFailed = true; }
      }
      if (!mounted) return;
      returning = _signedIn || complete;
      if (_signedIn && !initiallySignedIn) unawaited(_rememberReturningUser());
    }
    if (!mounted) return;
    // Real preference work gates the route. There is no minimum splash timer and
    // no requirement to wait for the decorative reveal before continuing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leaving) return;
      _leaving = true;
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        pageBuilder: (ctx, animation, secondary) => returning
            ? widget.homeBuilder?.call(ctx) ?? const HomeScreen()
            : OnboardingScreen(store: widget.store, homeBuilder: widget.homeBuilder,
                preferenceReadFailed: readFailed, preview: preview),
        transitionDuration: AppMotion.duration(context, AppMotion.route),
        reverseTransitionDuration: AppMotion.duration(context, AppMotion.route),
        transitionsBuilder: (ctx, animation, secondary, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: AppMotion.curve), child: child),
      ));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() { _reveal.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => EntryScaffold(child: Center(
    child: SingleChildScrollView(padding: const EdgeInsets.all(AppSpacing.page),
      child: AnimatedBuilder(animation: _reveal,
        child: const Column(mainAxisSize: MainAxisSize.min, children: [
          MindMark(size: 96), SizedBox(height: 24),
          Text('AI Mind', style: AppTypography.display), SizedBox(height: 10),
          Text('A little space for a clearer mind.', style: AppTypography.body, textAlign: TextAlign.center),
        ]),
        builder: (context, child) {
          final value = AppMotion.curve.transform(_reveal.value);
          return Semantics(label: 'AI Mind. Opening your space.',
            child: ExcludeSemantics(child: Opacity(opacity: .2 + value * .8,
              child: Transform.translate(offset: Offset(0, (1 - value) * 8),
                child: Transform.scale(scale: .94 + value * .06, child: child)))));
        },
      ),
    ),
  ));
}
