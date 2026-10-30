import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_tokens.dart';

abstract final class AppTheme {
  static const appearanceChannel = MethodChannel('ai_mind/appearance');
  static bool _darkNavigationIconsSupported = true;

  /// Android 24–25 cannot draw dark navigation icons on a light navigation bar.
  /// Resolve that capability once; no account or device identifier is collected.
  static Future<void> configurePlatformAppearance() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _darkNavigationIconsSupported = await appearanceChannel
          .invokeMethod<bool>('supportsDarkNavigationBar') ?? false;
    } on PlatformException {
      _darkNavigationIconsSupported = false;
    } on MissingPluginException {
      _darkNavigationIconsSupported = false;
    }
  }

  static final light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: AppColors.canvas,
    colorScheme: const ColorScheme.light(
      primary: AppColors.purple, onPrimary: AppColors.paper,
      secondary: AppColors.lavender, onSecondary: AppColors.ink,
      surface: AppColors.paper, onSurface: AppColors.ink,
      error: AppColors.errorInk, onError: AppColors.paper,
      outline: AppColors.controlOutline,
    ),
    textTheme: const TextTheme(
      displayLarge: AppTypography.display, headlineLarge: AppTypography.headline,
      titleLarge: AppTypography.title, bodyLarge: AppTypography.body,
      labelLarge: AppTypography.label, bodySmall: AppTypography.caption,
    ),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(AppSpacing.touchTarget, 56)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      textStyle: WidgetStatePropertyAll(AppTypography.label.copyWith(fontSize: 16)),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return AppColors.outline;
        if (states.contains(WidgetState.pressed)) return AppColors.purplePressed;
        return AppColors.purple;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? AppColors.secondaryInk : AppColors.paper),
      side: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.focused) ? const BorderSide(color: AppColors.focus, width: 3) : BorderSide.none),
      elevation: const WidgetStatePropertyAll(0),
      animationDuration: AppMotion.feedback,
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
      foregroundColor: AppColors.ink,
      minimumSize: const Size(AppSpacing.touchTarget, AppSpacing.touchTarget),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      textStyle: AppTypography.label,
      shape: const StadiumBorder(),
    ).copyWith(
      side: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused)
        ? const BorderSide(color: AppColors.focus, width: 2) : BorderSide.none),
    )),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.purple),
  );

  // One staged design system: preserve the deferred screens' existing appearance.
  static final legacy = ThemeData.dark().copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(primary: AppColors.accent,
        secondary: AppColors.accentLight, surface: AppColors.surface),
  );

  static SystemUiOverlayStyle get lightSystemUi => SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: _darkNavigationIconsSupported ? AppColors.canvas : AppColors.ink,
    systemNavigationBarIconBrightness: _darkNavigationIconsSupported ? Brightness.dark : Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );
  static const legacySystemUi = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: AppColors.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  );
}
