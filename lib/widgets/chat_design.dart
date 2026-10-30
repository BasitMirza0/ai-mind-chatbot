import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Conversation-only design tokens. Shared screens keep their existing theme.
abstract final class ChatDesign {
  static const body = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 15.5,
    height: 1.5,
    color: AppColors.ink,
  );
  static const gutter = 18.0;
  static const userWidth = .84;
  static const userRadius = BorderRadius.only(
    topLeft: Radius.circular(22),
    topRight: Radius.circular(22),
    bottomLeft: Radius.circular(22),
    bottomRight: Radius.circular(6),
  );
  static const identity = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: .3,
    color: AppColors.purple,
  );
}

class ChatGenerationIndicator extends StatefulWidget {
  const ChatGenerationIndicator({super.key});
  @override
  State<ChatGenerationIndicator> createState() =>
      _ChatGenerationIndicatorState();
}

class _ChatGenerationIndicatorState extends State<ChatGenerationIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      _pulse.stop();
      _pulse.value = .6;
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: 'AI Mind is responding',
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: .35, end: 1).animate(_pulse),
            child: const Icon(
              Icons.more_horiz_rounded,
              size: 20,
              color: AppColors.purple,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'Responding',
            style: TextStyle(fontSize: 12, color: AppColors.secondaryInk),
          ),
        ],
      ),
    ),
  );
}
