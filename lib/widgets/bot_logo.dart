import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class BotLogo extends StatelessWidget {
  final double size;
  const BotLogo({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient glow disc behind the robot
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.accentBlue.withValues(alpha: 0.45),
                  AppColors.accent.withValues(alpha: 0.22),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.50, 1.0],
              ),
            ),
          ),
          // 3-D robot PNG
          Image.asset(
            'assets/images/robot.png',
            width: size * 0.88,
            height: size * 0.88,
            fit: BoxFit.contain,
          ),
        ],
      ),
    );
  }
}
