import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Semantic palette for the light entry experience. Legacy tokens below remain
  // stable until the remaining screens are migrated in their approved phases.
  static const canvas = Color(0xFFF9F7F3);
  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF252331);
  static const secondaryInk = Color(0xFF686475);
  static const purple = Color(0xFF6551C8);
  static const purpleHighlight = Color(0xFF8871DD);
  static const purplePressed = Color(0xFF5140AB);
  static const lavender = Color(0xFFBBA9E9);
  static const lavenderSurface = Color(0xFFEEE8F8);
  static const lavenderPaper = Color(0xFFF5F0FC);
  static const peachSurface = Color(0xFFF6E8DC);
  static const outline = Color(0xFFE2DDE9);
  static const controlOutline = Color(0xFF82778F);
  static const errorInk = Color(0xFFA52D42);
  static const errorSurface = Color(0xFFFFEBEE);
  static const focus = Color(0xFF49309C);

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [purpleHighlight, purple],
  );

  static const entryWash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF8EDE2), Color(0xFFF1EAF9), canvas],
    stops: [0, 0.6, 1],
  );

  static const bg           = Color(0xFF08001A);
  static const surface      = Color(0xFF12002B);
  static const glass        = Color(0xFF1C0840);
  static const glassLight   = Color(0xFF26104E);
  static const border       = Color(0xFF4A1880);
  static const borderLight  = Color(0xFF7030B0);

  static const accent      = Color(0xFF9C27B0);
  static const accentLight = Color(0xFFBB86FC);
  static const accentPink  = Color(0xFFE040FB);
  static const accentBlue  = Color(0xFF7C4DFF);

  static const text   = Color(0xFFF0E6FF);
  static const muted  = Color(0xFF9E8ABF);
  static const dim    = Color(0xFF5A4A7A);

  static const gradTop    = Color(0xFF2D0855);
  static const gradMid    = Color(0xFF1A0535);
  static const gradBottom = Color(0xFF08001A);
}
