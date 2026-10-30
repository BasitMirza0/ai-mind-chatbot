import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Original AI Mind speech-face emblem, drawn with Flutter primitives.
class MindMark extends StatelessWidget {
  final double size;
  const MindMark({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: RepaintBoundary(
    child: CustomPaint(size: Size.square(size), painter: const _MindMarkPainter()),
  ));
}

class _MindMarkPainter extends CustomPainter {
  const _MindMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100),
        const Radius.circular(30)), Paint()..shader = AppColors.brandGradient
          .createShader(const Rect.fromLTWH(0, 0, 100, 100)));
    final face = Path.combine(PathOperation.union,
      Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(21, 25, 58, 45), const Radius.circular(17))),
      Path()..moveTo(34, 65)..lineTo(29, 80)..quadraticBezierTo(43, 77, 51, 65)..close());
    canvas.drawPath(face, Paint()..color = AppColors.paper);
    canvas.drawCircle(const Offset(40, 47), 4, Paint()..color = AppColors.purple);
    canvas.drawCircle(const Offset(60, 47), 4, Paint()..color = AppColors.purple);
    canvas.drawArc(const Rect.fromLTWH(43, 51, 14, 9), 0.15, 2.8, false,
        Paint()..color = AppColors.purple..style = PaintingStyle.stroke..strokeWidth = 2.3..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MindWordmark extends StatelessWidget {
  const MindWordmark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(label: 'AI Mind', child: ExcludeSemantics(
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const MindMark(size: 30), const SizedBox(width: AppSpacing.sm),
      Text('AI Mind', style: AppTypography.title.copyWith(fontSize: 18, fontWeight: FontWeight.w700)),
    ]),
  ));
}
