import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const section = 48.0;
  static const page = 24.0;
  static const contentWidth = 680.0;
  static const wideContentWidth = 1040.0;
  static const touchTarget = 48.0;
}

abstract final class AppRadii {
  static const sm = 12.0;
  static const card = 24.0;
  static const hero = 40.0;
  static const pill = 100.0;
}

abstract final class AppTypography {
  static const display = TextStyle(fontFamily: 'Roboto', fontSize: 44,
      fontWeight: FontWeight.w700, height: 1.08, letterSpacing: -1.6, color: AppColors.ink);
  static const headline = TextStyle(fontFamily: 'Roboto', fontSize: 40,
      fontWeight: FontWeight.w700, height: 1.12, letterSpacing: -1.3, color: AppColors.ink);
  static const title = TextStyle(fontFamily: 'Roboto', fontSize: 24,
      fontWeight: FontWeight.w500, height: 1.25, letterSpacing: -0.5, color: AppColors.ink);
  static const body = TextStyle(fontFamily: 'Roboto', fontSize: 16,
      fontWeight: FontWeight.w400, height: 1.55, color: AppColors.secondaryInk);
  static const label = TextStyle(fontFamily: 'Roboto', fontSize: 15,
      fontWeight: FontWeight.w500, height: 1.3, color: AppColors.ink);
  static const caption = TextStyle(fontFamily: 'Roboto', fontSize: 12,
      fontWeight: FontWeight.w400, height: 1.5, color: AppColors.secondaryInk);
  static const eyebrow = TextStyle(fontFamily: 'Roboto', fontSize: 11,
      fontWeight: FontWeight.w500, height: 1.4, letterSpacing: 1.8, color: AppColors.purple);
}

abstract final class AppMotion {
  static const feedback = Duration(milliseconds: 140);
  static const progress = Duration(milliseconds: 200);
  static const route = Duration(milliseconds: 280);
  static const page = Duration(milliseconds: 380);
  static const entrance = Duration(milliseconds: 480);
  static const settle = Duration(milliseconds: 900);
  static const curve = Curves.easeOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) || MediaQuery.accessibleNavigationOf(context);

  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;
}
