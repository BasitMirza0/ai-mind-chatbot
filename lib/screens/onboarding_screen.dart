import 'package:flutter/material.dart';

import '../config/app_debug_options.dart';
import '../services/onboarding_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/entry_components.dart';
import '../widgets/mind_mark.dart';
import '../widgets/onboarding_illustration.dart';
import 'home_screen.dart';

const _pages = [
  (eyebrow: 'A SPACE TO THINK', title: 'A clearer mind,\none chat away.',
    body: 'Ask a question, explore a thought, or work through what comes next.'),
  (eyebrow: 'FROM THOUGHT TO WORDS', title: 'Find the words.\nMake them yours.',
    body: 'From a first draft to a fresh perspective, start with a conversation.'),
  (eyebrow: 'KEEP THE GOOD THOUGHTS', title: 'Good thoughts.\nWorth keeping.',
    body: 'Sign in to save and revisit your chats. You can look around as a guest.'),
];

class OnboardingScreen extends StatefulWidget {
  final OnboardingStore store;
  final WidgetBuilder? homeBuilder;
  final bool preferenceReadFailed;
  final bool preview;
  const OnboardingScreen({super.key, this.store = const PreferencesOnboardingStore(),
    this.homeBuilder, this.preferenceReadFailed = false, this.preview = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  bool _paging = false;
  bool _saving = false;
  bool _finished = false;
  bool _saveFailed = false;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  Future<void> _changePage(int next) async {
    if (_saving || _paging || _finished || !_controller.hasClients || next < 0 || next >= _pages.length) return;
    setState(() => _paging = true);
    try {
      if (AppMotion.reduced(context)) {
        _controller.jumpToPage(next);
      } else {
        await _controller.animateToPage(next, duration: AppMotion.page, curve: AppMotion.curve);
      }
    } finally {
      if (mounted) setState(() => _paging = false);
    }
  }

  void _goHome() {
    if (!mounted || _finished) return;
    _finished = true;
    Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      pageBuilder: (ctx, animation, secondary) => widget.homeBuilder?.call(ctx) ?? const HomeScreen(),
      transitionDuration: AppMotion.duration(context, AppMotion.route),
      reverseTransitionDuration: AppMotion.duration(context, AppMotion.route),
      transitionsBuilder: (ctx, animation, secondary, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: AppMotion.curve), child: child),
    ));
  }

  Future<void> _finish() async {
    if (_saving || _paging || _finished) return;
    setState(() { _saving = true; _saveFailed = false; });
    try {
      // Preview is read-only, including for signed-in users with a saved flag.
      // Requiring the compile-time debug gate here prevents a release bypass.
      if (!(AppDebugOptions.forceOnboarding && widget.preview)) {
        await widget.store.markComplete();
      }
      if (mounted) _goHome();
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height < 580;
    final unavailable = _saving || _paging || _finished;
    return PopScope<void>(
      canPop: _page == 0 && !unavailable,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _page > 0 && !unavailable) _changePage(_page - 1);
      },
      child: EntryScaffold(child: FocusTraversalGroup(child: Column(children: [
        _EntryWidth(child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpacing.page, compact ? 0 : 8, AppSpacing.page, compact ? 4 : 12),
          child: Column(children: [
            Row(children: [
              const MindWordmark(), const Spacer(),
              TextButton(key: const Key('onboarding-skip'), onPressed: unavailable ? null : _finish,
                child: const Text('Skip intro')),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              OnboardingProgress(index: _page, count: _pages.length),
              ExcludeSemantics(child: Text('0${_page + 1} / 0${_pages.length}', style: AppTypography.caption)),
            ]),
          ]),
        )),
        Expanded(child: PageView.builder(
          key: const Key('onboarding-pages'), controller: _controller,
          itemCount: _pages.length,
          physics: _saving || _finished ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
          onPageChanged: (page) => setState(() { _page = page; _saveFailed = false; }),
          itemBuilder: (context, index) => _OnboardingPage(
            index: index, active: index == _page,
            readFailed: widget.preferenceReadFailed && index == 0,
            saveFailed: _saveFailed && index == _page,
            onContinueWithoutSaving: _goHome,
          ),
        )),
        _EntryWidth(child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, compact ? 8 : 16),
          child: Column(children: [
            Row(children: [
              if (_page > 0) SizedBox(width: 88, child: TextButton(
                key: const Key('onboarding-back'),
                onPressed: _page == 0 || unavailable ? null : () => _changePage(_page - 1),
                child: const Text('Back'),
              )),
              if (_page > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(child: EntryPrimaryButton(
                key: const Key('onboarding-next'), busy: _saving,
                label: _saveFailed ? 'Try again' : _page == _pages.length - 1 ? 'Get started' : 'Next',
                onPressed: unavailable ? null : _saveFailed || _page == _pages.length - 1
                  ? _finish : () => _changePage(_page + 1),
              )),
            ]),
            if (!compact) ...[
              const SizedBox(height: 12),
              const Text('AI features require sign-in.', style: AppTypography.caption, textAlign: TextAlign.center),
            ],
          ]),
        )),
      ]))),
    );
  }
}

class _EntryWidth extends StatelessWidget {
  final Widget child;
  const _EntryWidth({required this.child});

  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width > 700
      ? AppSpacing.wideContentWidth : AppSpacing.contentWidth), child: child));
}

class _OnboardingPage extends StatelessWidget {
  final int index;
  final bool active;
  final bool readFailed;
  final bool saveFailed;
  final VoidCallback onContinueWithoutSaving;
  const _OnboardingPage({required this.index, required this.active,
    required this.readFailed, required this.saveFailed, required this.onContinueWithoutSaving});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final wide = box.maxWidth >= 640 && MediaQuery.orientationOf(context) == Orientation.landscape;
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 23;
    final heroHeight = largeText
      ? (box.maxHeight * .20).clamp(100.0, 160.0)
      : (box.maxHeight * .53).clamp(170.0, 340.0);
    final page = _pages[index];
    final titleSize = wide ? 34.0 : box.maxWidth < 375 ? 36.0 : 40.0;
    final copy = Padding(padding: const EdgeInsets.fromLTRB(AppSpacing.page, 16, AppSpacing.page, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(page.eyebrow, style: AppTypography.eyebrow),
        const SizedBox(height: 12),
        Semantics(header: true, child: Text(page.title, style: AppTypography.headline.copyWith(fontSize: titleSize))),
        const SizedBox(height: 16),
        Text(page.body, style: AppTypography.body),
        if (readFailed || saveFailed) ...[
          const SizedBox(height: 16),
          EntrySurface(color: saveFailed ? AppColors.errorSurface : AppColors.paper,
            child: Semantics(liveRegion: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(saveFailed ? 'Couldn’t save your intro preference. Try again, or continue for now.'
                  : 'Your intro preference couldn’t be read. You can still continue.',
                style: AppTypography.body.copyWith(fontSize: 14,
                    color: saveFailed ? AppColors.errorInk : AppColors.secondaryInk)),
              if (saveFailed) TextButton(onPressed: onContinueWithoutSaving, child: const Text('Continue for now')),
            ])),
          ),
        ],
      ]));
    final art = SizedBox(height: heroHeight, child: Center(child: AspectRatio(
      aspectRatio: 360 / 320, child: OnboardingIllustration(page: index, active: active))));
    return _EntryWidth(child: SingleChildScrollView(
      primary: false,
      key: Key('onboarding-scroll-$index'),
      padding: const EdgeInsets.only(bottom: 8),
      child: ConstrainedBox(constraints: BoxConstraints(minHeight: (box.maxHeight - 8).clamp(0, double.infinity)),
        child: wide ? Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          SizedBox(width: box.maxWidth.clamp(0, AppSpacing.wideContentWidth) * .37, child: art),
          Expanded(child: copy),
        ])) : Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [art, copy]),
      ),
    ));
  });
}
