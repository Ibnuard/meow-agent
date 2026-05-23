import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Extra design tokens that don't fit the standard ColorScheme.
/// Accessed via `context.extras` (see extension below).
@immutable
class MeowExtras extends ThemeExtension<MeowExtras> {
  const MeowExtras({
    required this.card,
    required this.subtleText,
    required this.subtleBorder,
    required this.success,
    required this.navBackground,
    required this.navInactive,
    required this.navActive,
    required this.navBorder,
    required this.gradientEnd,
    required this.inputFill,
    required this.inputBorder,
    required this.inputFocusBorder,
    required this.inputFocusGlow,
  });

  final Color card;
  final Color subtleText;
  final Color subtleBorder;
  final Color success;
  final Color navBackground;
  final Color navInactive;
  final Color navActive;
  final Color navBorder;
  final Color gradientEnd;
  final Color inputFill;
  final Color inputBorder;
  final Color inputFocusBorder;
  final Color inputFocusGlow;

  static const light = MeowExtras(
    card: Color(0xFFF7F8FA),
    subtleText: Color(0xFF94A3B8),
    subtleBorder: Color(0xFFF1F5F9),
    success: Color(0xFF22C55E),
    navBackground: Color(0xE6FFFFFF), // white 90% opacity
    navInactive: Color(0xFF94A3B8),
    navActive: Color(0xFF0F172A),
    navBorder: Color(0x1A000000), // black 10%
    gradientEnd: Color(0xFF1E40AF),
    inputFill: Color(0xFFF1F5F9),
    inputBorder: Color(0xFFE2E8F0),
    inputFocusBorder: Color(0xFF3B82F6),
    inputFocusGlow: Color(0x1A3B82F6),
  );

  static const dark = MeowExtras(
    card: Color(0xD90F172A), // rgba(15,23,42,0.85)
    subtleText: Color(0xFF64748B),
    subtleBorder: Color(0x14FFFFFF), // rgba(255,255,255,0.08)
    success: Color(0xFF22C55E),
    navBackground: Color(0xBF0F172A), // dark navy 75%
    navInactive: Color(0xFF64748B),
    navActive: Colors.white,
    navBorder: Color(0x14FFFFFF), // white 8%
    gradientEnd: Color(0xFF1E3A8A),
    inputFill: Color(0xFF0F172A),
    inputBorder: Color(0x14FFFFFF), // rgba(255,255,255,0.08)
    inputFocusBorder: Color(0xFF3B82F6),
    inputFocusGlow: Color(0x333B82F6),
  );

  @override
  MeowExtras copyWith({
    Color? card,
    Color? subtleText,
    Color? subtleBorder,
    Color? success,
    Color? navBackground,
    Color? navInactive,
    Color? navActive,
    Color? navBorder,
    Color? gradientEnd,
    Color? inputFill,
    Color? inputBorder,
    Color? inputFocusBorder,
    Color? inputFocusGlow,
  }) {
    return MeowExtras(
      card: card ?? this.card,
      subtleText: subtleText ?? this.subtleText,
      subtleBorder: subtleBorder ?? this.subtleBorder,
      success: success ?? this.success,
      navBackground: navBackground ?? this.navBackground,
      navInactive: navInactive ?? this.navInactive,
      navActive: navActive ?? this.navActive,
      navBorder: navBorder ?? this.navBorder,
      gradientEnd: gradientEnd ?? this.gradientEnd,
      inputFill: inputFill ?? this.inputFill,
      inputBorder: inputBorder ?? this.inputBorder,
      inputFocusBorder: inputFocusBorder ?? this.inputFocusBorder,
      inputFocusGlow: inputFocusGlow ?? this.inputFocusGlow,
    );
  }

  @override
  MeowExtras lerp(ThemeExtension<MeowExtras>? other, double t) {
    if (other is! MeowExtras) return this;
    return MeowExtras(
      card: Color.lerp(card, other.card, t)!,
      subtleText: Color.lerp(subtleText, other.subtleText, t)!,
      subtleBorder: Color.lerp(subtleBorder, other.subtleBorder, t)!,
      success: Color.lerp(success, other.success, t)!,
      navBackground: Color.lerp(navBackground, other.navBackground, t)!,
      navInactive: Color.lerp(navInactive, other.navInactive, t)!,
      navActive: Color.lerp(navActive, other.navActive, t)!,
      navBorder: Color.lerp(navBorder, other.navBorder, t)!,
      gradientEnd: Color.lerp(gradientEnd, other.gradientEnd, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      inputBorder: Color.lerp(inputBorder, other.inputBorder, t)!,
      inputFocusBorder: Color.lerp(inputFocusBorder, other.inputFocusBorder, t)!,
      inputFocusGlow: Color.lerp(inputFocusGlow, other.inputFocusGlow, t)!,
    );
  }
}

/// Convenience accessors used across the app.
extension MeowThemeX on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
  MeowExtras get extras => Theme.of(this).extension<MeowExtras>()!;
}

class MeowTheme {
  static const _accentLight = Color(0xFF2563EB);
  static const _accentDark = Color(0xFF3B82F6);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accentLight,
      brightness: Brightness.light,
    ).copyWith(
      primary: _accentLight,
      onPrimary: Colors.white,
      surface: const Color(0xFFFFFFFF),
      onSurface: const Color(0xFF0F172A),
      onSurfaceVariant: const Color(0xFF64748B),
      outline: const Color(0xFFCBD5E1),
      outlineVariant: const Color(0xFFE2E8F0),
      error: const Color(0xFFEF4444),
    );
    return _build(scheme: scheme, extras: MeowExtras.light);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accentDark,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _accentDark,
      onPrimary: Colors.white,
      surface: const Color(0xFF020817),
      onSurface: const Color(0xFFE5E7EB),
      onSurfaceVariant: const Color(0xFF94A3B8),
      outline: const Color(0xFF374151),
      outlineVariant: const Color(0x14FFFFFF), // rgba(255,255,255,0.08)
      error: const Color(0xFFEF4444),
    );
    return _build(scheme: scheme, extras: MeowExtras.dark);
  }

  static ThemeData _build({
    required ColorScheme scheme,
    required MeowExtras extras,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
    );

    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: [extras],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: extras.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: extras.subtleBorder, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: extras.subtleBorder, width: 1),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      // We override InputDecorationTheme to a minimal base. The actual
      // styled inputs use MeowInput which applies its own decoration.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: extras.inputFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: GoogleFonts.inter(
          color: extras.subtleText,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        labelStyle: GoogleFonts.inter(
          color: scheme.onSurfaceVariant,
          fontSize: 14,
        ),
        errorStyle: GoogleFonts.inter(
          color: const Color(0xFFFCA5A5),
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.2,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: extras.inputBorder, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: extras.inputBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: extras.inputFocusBorder, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: const Color(0xFFF87171).withValues(alpha: 0.65),
            width: 1,
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: const Color(0xFFF87171).withValues(alpha: 0.75),
            width: 1,
          ),
        ),
      ),
      dividerColor: extras.subtleBorder,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.brightness == Brightness.dark
            ? const Color(0xFF0F172A)
            : scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    );
  }
}
