import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Three original compositions. The robot is AI Mind's existing local artwork;
/// paper, speech, orbit and archive motifs are drawn here, never from references.
class OnboardingIllustration extends StatefulWidget {
  final int page;
  final bool active;
  const OnboardingIllustration({super.key, required this.page, required this.active});

  @override
  State<OnboardingIllustration> createState() => _OnboardingIllustrationState();
}

class _OnboardingIllustrationState extends State<OnboardingIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(vsync: this, duration: AppMotion.settle);
  bool? _reduced;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduced(context);
    if (_reduced != reduced) {
      _reduced = reduced;
      _start();
    }
  }

  @override
  void didUpdateWidget(covariant OnboardingIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _start();
  }

  void _start() {
    _entrance.stop();
    if (_reduced == true || !widget.active) {
      _entrance.value = 1;
    } else {
      _entrance.forward(from: 0);
    }
  }

  @override
  void dispose() { _entrance.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: AnimatedBuilder(
    animation: _entrance,
    child: RepaintBoundary(child: FittedBox(fit: BoxFit.contain, child: SizedBox(
      width: 360, height: 320,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _IllustrationPainter(widget.page))),
        if (widget.page == 0) Positioned(left: 101, top: 40, width: 166, height: 235,
          child: Image.asset('assets/images/robot.png', fit: BoxFit.contain,
              filterQuality: FilterQuality.medium)),
      ]),
    ))),
    builder: (context, child) {
      final value = AppMotion.curve.transform(_entrance.value);
      return Opacity(opacity: (value * 2).clamp(0, 1), child: Transform.translate(
        offset: Offset(0, (1 - value) * 12 - math.sin(value * math.pi) * 3),
        child: Transform.scale(scale: 0.975 + value * 0.025, child: child),
      ));
    },
  ));
}

class _IllustrationPainter extends CustomPainter {
  final int page;
  const _IllustrationPainter(this.page);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 360, size.height / 320);
    final wash = Paint()..shader = RadialGradient(colors: [
      page == 1 ? AppColors.peachSurface : AppColors.lavenderSurface,
      AppColors.canvas.withValues(alpha: 0),
    ]).createShader(const Rect.fromLTWH(12, 0, 336, 320));
    canvas.drawCircle(const Offset(180, 157), 155, wash);
    canvas.drawOval(const Rect.fromLTWH(93, 282, 174, 12), Paint()..color = AppColors.purple.withValues(alpha: 0.055));
    if (page == 0) {
      _conversation(canvas);
    } else if (page == 1) {
      _writing(canvas);
    } else {
      _archive(canvas);
    }
  }

  void _card(Canvas canvas, Rect rect, {double radius = 18, Color color = AppColors.paper}) {
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(shape.shift(const Offset(0, 3)), Paint()..color = AppColors.purple.withValues(alpha: 0.04));
    canvas.drawRRect(shape, Paint()..color = color);
    canvas.drawRRect(shape, Paint()..color = AppColors.outline..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  void _line(Canvas canvas, double x, double y, double width, {Color color = AppColors.outline, double height = 5}) {
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, width, height), const Radius.circular(3)), Paint()..color = color);
  }

  void _label(Canvas canvas, String text, Offset offset, {double size = 12, Color color = AppColors.ink}) {
    final painter = TextPainter(text: TextSpan(text: text,
      style: TextStyle(fontFamily: 'Roboto', fontSize: size, fontWeight: FontWeight.w500, color: color)),
      textDirection: TextDirection.ltr)..layout();
    painter.paint(canvas, offset);
    painter.dispose();
  }

  void _spark(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path()..moveTo(center.dx, center.dy - radius)
      ..quadraticBezierTo(center.dx + radius * .2, center.dy - radius * .2, center.dx + radius, center.dy)
      ..quadraticBezierTo(center.dx + radius * .2, center.dy + radius * .2, center.dx, center.dy + radius)
      ..quadraticBezierTo(center.dx - radius * .2, center.dy + radius * .2, center.dx - radius, center.dy)
      ..quadraticBezierTo(center.dx - radius * .2, center.dy - radius * .2, center.dx, center.dy - radius)..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _conversation(Canvas canvas) {
    canvas.drawArc(const Rect.fromLTWH(54, 45, 252, 232), -.9, 4.5, false,
      Paint()..color = AppColors.lavender.withValues(alpha: .5)..style = PaintingStyle.stroke..strokeWidth = 1);
    _spark(canvas, const Offset(287, 66), 12, AppColors.purple);
    _spark(canvas, const Offset(69, 226), 7, AppColors.lavender);
    canvas.save();
    canvas.translate(23, 78); canvas.rotate(-.07);
    _card(canvas, const Rect.fromLTWH(0, 0, 131, 48));
    canvas.drawCircle(const Offset(22, 24), 10, Paint()..color = AppColors.lavenderSurface);
    _spark(canvas, const Offset(22, 24), 5, AppColors.purple);
    _label(canvas, 'A fresh thought', const Offset(39, 17), size: 10.5);
    canvas.restore();
    canvas.save();
    canvas.translate(233, 213); canvas.rotate(.06);
    _card(canvas, const Rect.fromLTWH(0, 0, 105, 63), color: AppColors.purple);
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(30 + i * 21, 25), 3.5, Paint()..color = AppColors.paper);
    }
    _line(canvas, 23, 42, 60, color: AppColors.paper.withValues(alpha: .4), height: 3);
    canvas.restore();
  }

  void _writing(Canvas canvas) {
    canvas.save();
    canvas.translate(177, 153); canvas.rotate(-.065); canvas.translate(-177, -153);
    _card(canvas, const Rect.fromLTWH(91, 35, 178, 232), radius: 22);
    final fold = Path()..moveTo(235, 36)..lineTo(268, 69)..lineTo(248, 69)
      ..quadraticBezierTo(235, 69, 235, 56)..close();
    canvas.drawPath(fold, Paint()..color = AppColors.lavenderSurface);
    _label(canvas, 'A brighter draft', const Offset(112, 78), size: 14);
    _line(canvas, 113, 114, 127);
    _line(canvas, 113, 129, 104);
    _line(canvas, 113, 155, 132, color: AppColors.lavenderSurface, height: 20);
    _line(canvas, 120, 163, 104, color: AppColors.lavender, height: 4);
    _line(canvas, 113, 191, 120);
    _line(canvas, 113, 206, 88);
    canvas.restore();
    canvas.save();
    canvas.translate(279, 105); canvas.rotate(.52);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-12, 0, 24, 142), const Radius.circular(8)), Paint()..color = AppColors.purple);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-12, -14, 24, 29), const Radius.circular(8)), Paint()..color = AppColors.lavender);
    _line(canvas, -7, 20, 4, color: AppColors.paper.withValues(alpha: .4), height: 111);
    final tip = Path()..moveTo(-12, 140)..lineTo(0, 164)..lineTo(12, 140)..close();
    canvas.drawPath(tip, Paint()..color = AppColors.peachSurface);
    final nib = Path()..moveTo(-4, 156)..lineTo(0, 164)..lineTo(4, 156)..close();
    canvas.drawPath(nib, Paint()..color = AppColors.ink);
    canvas.restore();
    _card(canvas, const Rect.fromLTWH(24, 218, 166, 47), radius: 16);
    _spark(canvas, const Offset(47, 242), 6, AppColors.purple);
    _label(canvas, 'Make it your own', const Offset(62, 235), size: 11.5);
    _spark(canvas, const Offset(64, 69), 10, AppColors.lavender);
  }

  void _archive(Canvas canvas) {
    canvas.save(); canvas.translate(180, 141); canvas.rotate(.1); canvas.translate(-180, -141);
    _card(canvas, const Rect.fromLTWH(110, 42, 168, 177), radius: 18, color: AppColors.lavenderPaper);
    canvas.restore();
    canvas.save(); canvas.translate(170, 141); canvas.rotate(-.09); canvas.translate(-170, -141);
    _card(canvas, const Rect.fromLTWH(82, 58, 178, 181), radius: 18);
    _line(canvas, 103, 84, 90, color: AppColors.lavender, height: 6);
    _line(canvas, 103, 102, 132);
    canvas.restore();
    final folder = Path()..moveTo(55, 143)..quadraticBezierTo(55, 125, 73, 125)
      ..lineTo(132, 125)..lineTo(150, 143)..lineTo(287, 143)
      ..quadraticBezierTo(305, 143, 305, 161)..lineTo(299, 259)
      ..quadraticBezierTo(298, 277, 280, 277)..lineTo(78, 277)
      ..quadraticBezierTo(60, 277, 59, 259)..close();
    canvas.drawPath(folder, Paint()..color = AppColors.lavender);
    _card(canvas, const Rect.fromLTWH(78, 162, 204, 94), radius: 17);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(96, 181, 28, 25), const Radius.circular(9)), Paint()..color = AppColors.lavenderSurface);
    canvas.drawCircle(const Offset(106, 193), 2, Paint()..color = AppColors.purple);
    canvas.drawCircle(const Offset(115, 193), 2, Paint()..color = AppColors.purple);
    _label(canvas, 'Room for your ideas', const Offset(136, 186), size: 11.5);
    _line(canvas, 97, 222, 156);
    _line(canvas, 97, 235, 119);
    _spark(canvas, const Offset(298, 85), 11, AppColors.purple);
    _spark(canvas, const Offset(56, 214), 6, AppColors.peachSurface);
  }

  @override
  bool shouldRepaint(covariant _IllustrationPainter oldDelegate) => oldDelegate.page != page;
}
