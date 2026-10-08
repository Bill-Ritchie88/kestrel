import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens from the Figma file "Project Kestrel - UI", page
/// 01 · Design System (kestrel-ui-design-system.md).
///
/// Contrast was checked against WCAG 2.1 AA (4.5:1 for text) before use:
/// - text/muted #6B6F7D reaches only 3.95:1 on bg/base, so it is used for
///   decoration and disabled states, never for text a passenger must read;
/// - crimson/500 #D81B3C reaches 3.9:1 as text, so crimson TEXT uses
///   crimson/glow #FF2E55 (5.4:1); crimson/500 stays a fill, where white text
///   on it reaches 5.1:1.
class K {
  /// Inter is fetched by google_fonts at run time. Widget tests have no
  /// network, so they switch this off and fall back to the platform font.
  static bool useGoogleFonts = true;

  static TextStyle inter({
    double? fontSize,
    double? height,
    FontWeight? fontWeight,
    double? letterSpacing,
    Color? color,
    List<FontFeature>? fontFeatures,
  }) {
    final style = TextStyle(
      fontSize: fontSize,
      height: height,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: fontFeatures,
    );
    return useGoogleFonts ? GoogleFonts.inter(textStyle: style) : style;
  }

  // Surfaces
  static const void_ = Color(0xFF060608);
  static const base = Color(0xFF0A0A0F);
  static const inset = Color(0xFF0D0D12);
  static const surface = Color(0xFF121218);
  static const elevated = Color(0xFF1A1A22);
  static const hairline = Color(0xFF26262F);

  // Crimson
  static const glow = Color(0xFFFF2E55);
  static const crimson = Color(0xFFD81B3C);
  static const crimson600 = Color(0xFFA81030);
  static const crimson700 = Color(0xFF6E0A20);
  static const crimsonStroke = Color(0xFF4A1020);

  // Content and signal
  static const textPrimary = Color(0xFFF2F3F7);
  static const textSecondary = Color(0xFFA0A4B2);
  static const muted = Color(0xFF6B6F7D);
  static const teal = Color(0xFF23C79A);
  static const amber = Color(0xFFE2A33C);
  static const sky = Color(0xFFDCE3EF);

  /// 4/8 spacing rhythm.
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 24.0, s6 = 32.0;
  static const radius = 16.0;

  /// Minimum touch target (48 dp, Android; >= 44 pt iOS).
  static const touch = 48.0;

  static const primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [crimson, crimson600],
  );

  static TextStyle label(BuildContext c) => inter(
        fontSize: 11,
        height: 14 / 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.66,
        color: textSecondary,
      );

  static TextStyle dataLg(BuildContext c) => inter(
        fontSize: 22,
        height: 26 / 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle dataMd(BuildContext c) => inter(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w500,
        color: textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

ThemeData kestrelTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final textBase =
      K.useGoogleFonts ? GoogleFonts.interTextTheme(base.textTheme) : base.textTheme;
  final text = textBase.copyWith(
    displaySmall: K.inter(
        fontSize: 34, height: 40 / 34, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineSmall: K.inter(
        fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w600, letterSpacing: -0.24),
    titleLarge: K.inter(
        fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w600, letterSpacing: -0.1),
    titleMedium: K.inter(
        fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, letterSpacing: -0.03),
    bodyLarge: K.inter(fontSize: 16, height: 1.5),
    bodyMedium: K.inter(fontSize: 15, height: 22 / 15),
    bodySmall: K.inter(fontSize: 13, height: 19 / 13),
    labelLarge: K.inter(fontSize: 15, fontWeight: FontWeight.w600),
    labelMedium: K.inter(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500),
  ).apply(bodyColor: K.textPrimary, displayColor: K.textPrimary);

  return base.copyWith(
    scaffoldBackgroundColor: K.base,
    colorScheme: const ColorScheme.dark(
      primary: K.crimson,
      onPrimary: Colors.white,
      secondary: K.teal,
      onSecondary: K.base,
      surface: K.surface,
      onSurface: K.textPrimary,
      error: K.glow,
      onError: Colors.white,
      outline: K.hairline,
    ),
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: K.textPrimary,
      titleTextStyle: text.titleLarge,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: K.inset,
      contentPadding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: 18),
      hintStyle: text.bodyMedium?.copyWith(color: K.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(K.radius),
        borderSide: const BorderSide(color: K.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(K.radius),
        borderSide: const BorderSide(color: K.hairline),
      ),
      // Visible focus for keyboard users.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(K.radius),
        borderSide: const BorderSide(color: K.glow, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(K.radius),
        borderSide: const BorderSide(color: K.glow),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(K.radius),
        borderSide: const BorderSide(color: K.glow, width: 2),
      ),
      errorStyle: text.bodySmall?.copyWith(color: K.glow),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: K.elevated,
      contentTextStyle: text.bodyMedium,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: K.glow),
    focusColor: K.glow.withAlpha(60),
  );
}
