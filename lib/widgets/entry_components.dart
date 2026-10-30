import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class EntryScaffold extends StatelessWidget {
  final Widget child;
  const EntryScaffold({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.light,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.lightSystemUi,
      child: Scaffold(backgroundColor: AppColors.canvas, body: SafeArea(
        child: LayoutBuilder(builder: (context, box) => box.maxHeight < 300
          ? SingleChildScrollView(primary: false, child: SizedBox(height: 360, child: child))
          : child),
      )),
    ),
  );
}

class EntrySurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  const EntrySurface({super.key, required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg), this.color = AppColors.paper});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.outline)),
    child: Padding(padding: padding, child: child),
  );
}

class EntryLoadingIndicator extends StatelessWidget {
  final String label;
  const EntryLoadingIndicator({super.key, this.label = 'Saving your preference'});

  @override
  Widget build(BuildContext context) => Semantics(label: label, child: ExcludeSemantics(
    child: SizedBox.square(dimension: 20, child: AppMotion.reduced(context)
      ? const Icon(Icons.hourglass_bottom_rounded, size: 20)
      : const CircularProgressIndicator(strokeWidth: 2)),
  ));
}

class EntryPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const EntryPrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      if (busy) ...[const EntryLoadingIndicator(), const SizedBox(width: AppSpacing.sm)],
      Flexible(child: Text(busy ? 'Saving…' : label, textAlign: TextAlign.center)),
      if (!busy) ...[const SizedBox(width: AppSpacing.sm), const Icon(Icons.arrow_forward_rounded, size: 18)],
    ]),
  );
}

class OnboardingProgress extends StatelessWidget {
  final int index;
  final int count;
  const OnboardingProgress({super.key, required this.index, required this.count});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Introduction, page ${index + 1} of $count', liveRegion: true,
    child: ExcludeSemantics(child: Row(mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (i) => AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.progress), curve: AppMotion.curve,
        width: i == index ? 32 : 16, height: 4,
        margin: EdgeInsetsDirectional.only(end: i == count - 1 ? 0 : 6),
        decoration: BoxDecoration(color: i == index ? AppColors.purple : AppColors.lavender,
            borderRadius: BorderRadius.circular(AppRadii.pill)),
      )),
    )),
  );
}
