import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'design_tokens.dart';

/// Parachute App Theme
///
/// "Think naturally" - Calm, spacious, grounded.
///
/// This theme embodies the Parachute brand: technology that gives you space
/// rather than demands your attention. Nature-inspired colors, soft edges,
/// generous spacing, and gentle motion.

class AppTheme {
  /// Light theme for Parachute
  static ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.light(
      // Primary - Forest Green (grounded, trustworthy)
      primary: BrandColors.forest,
      onPrimary: BrandColors.softWhite,
      primaryContainer: BrandColors.forestMist,
      onPrimaryContainer: BrandColors.forestDeep,

      // Secondary - Turquoise (flow, clarity)
      secondary: BrandColors.turquoise,
      onSecondary: BrandColors.softWhite,
      secondaryContainer: BrandColors.turquoiseMist,
      onSecondaryContainer: BrandColors.turquoiseDeep,

      // Tertiary - Warm accent (removed purple, using warm amber)
      tertiary: BrandColors.warning,
      onTertiary: BrandColors.softWhite,

      // Error - Soft terracotta (serious but not aggressive)
      error: BrandColors.error,
      onError: BrandColors.softWhite,
      errorContainer: BrandColors.errorLight,
      onErrorContainer: BrandColors.error,

      // Surfaces - Warm, creamy tones
      surface: BrandColors.cream,
      onSurface: BrandColors.charcoal,
      surfaceContainerHighest: BrandColors.stone,

      // Other
      outline: BrandColors.driftwood,
      outlineVariant: BrandColors.stone,
      shadow: BrandColors.charcoal,
      inversePrimary: BrandColors.nightForest,
    ),
    brightness: Brightness.light,

    // AppBar - Clean, elevated feeling
    appBarTheme: AppBarTheme(
      backgroundColor: BrandColors.cream,
      foregroundColor: BrandColors.charcoal,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.titleLarge,
        fontWeight: FontWeight.w600,
        color: BrandColors.charcoal,
        letterSpacing: TypographyTokens.letterSpacingTight,
      ),
      iconTheme: const IconThemeData(
        color: BrandColors.charcoal,
        size: 22,
      ),
    ),

    // Text theme - Inter with warm application
    textTheme: _buildTextTheme(BrandColors.charcoal),

    // Bottom Navigation - Grounded, subtle
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: BrandColors.softWhite,
      selectedItemColor: BrandColors.forest,
      unselectedItemColor: BrandColors.driftwood,
      selectedLabelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.normal,
      ),
      type: BottomNavigationBarType.fixed,
      elevation: Elevation.low,
    ),

    // FAB - Primary action, inviting
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: BrandColors.forest,
      foregroundColor: BrandColors.softWhite,
      elevation: Elevation.medium,
      highlightElevation: Elevation.high,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    ),

    // Cards - Soft, elevated pebbles
    cardTheme: CardThemeData(
      elevation: Elevation.low,
      color: BrandColors.softWhite,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      margin: EdgeInsets.zero,
    ),

    // Dialogs - Generous, calming
    dialogTheme: DialogThemeData(
      backgroundColor: BrandColors.softWhite,
      surfaceTintColor: Colors.transparent,
      elevation: Elevation.high,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      titleTextStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.headlineMedium,
        fontWeight: FontWeight.w600,
        color: BrandColors.charcoal,
      ),
    ),

    // Buttons - Soft, inviting
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: BrandColors.forest,
        foregroundColor: BrandColors.softWhite,
        elevation: Elevation.low,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: Spacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BrandColors.forest,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: Spacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        side: const BorderSide(color: BrandColors.forest, width: 1.5),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BrandColors.forest,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.sm,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),

    // Input decoration - Clean, spacious
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BrandColors.softWhite,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: BrandColors.stone),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: BrandColors.stone),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: BrandColors.forest, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: BrandColors.error),
      ),
      hintStyle: GoogleFonts.inter(
        color: BrandColors.driftwood,
        fontSize: TypographyTokens.bodyMedium,
      ),
    ),

    // Snackbar - Subtle feedback
    snackBarTheme: SnackBarThemeData(
      backgroundColor: BrandColors.charcoal,
      contentTextStyle: GoogleFonts.inter(
        color: BrandColors.cream,
        fontSize: TypographyTokens.bodyMedium,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // Divider - Subtle separators
    dividerTheme: const DividerThemeData(
      color: BrandColors.stone,
      thickness: 1,
      space: 1,
    ),

    // Chip - Soft badges
    chipTheme: ChipThemeData(
      backgroundColor: BrandColors.forestMist,
      labelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.w500,
        color: BrandColors.forest,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    ),

    // Progress indicator
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: BrandColors.turquoise,
      linearTrackColor: BrandColors.stone,
      circularTrackColor: BrandColors.stone,
    ),

    // Icon theme
    iconTheme: const IconThemeData(
      color: BrandColors.charcoal,
      size: 24,
    ),

    // List tile
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
  );

  /// Dark theme for Parachute
  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.dark(
      // Primary - Lighter forest for dark mode visibility
      primary: BrandColors.nightForest,
      onPrimary: BrandColors.nightSurface,
      primaryContainer: BrandColors.forestDeep,
      onPrimaryContainer: BrandColors.nightForest,

      // Secondary - Lighter turquoise
      secondary: BrandColors.nightTurquoise,
      onSecondary: BrandColors.nightSurface,
      secondaryContainer: BrandColors.turquoiseDeep,
      onSecondaryContainer: BrandColors.nightTurquoise,

      // Tertiary
      tertiary: BrandColors.warning,
      onTertiary: BrandColors.nightSurface,

      // Error
      error: const Color(0xFFE8A090),
      onError: BrandColors.nightSurface,
      errorContainer: const Color(0xFF5A3A34),
      onErrorContainer: const Color(0xFFE8A090),

      // Surfaces - Warm dark tones
      surface: BrandColors.nightSurface,
      onSurface: BrandColors.nightText,
      surfaceContainerHighest: BrandColors.nightSurfaceElevated,

      // Other
      outline: BrandColors.nightTextSecondary,
      outlineVariant: const Color(0xFF3A3836),
      shadow: Colors.black,
      inversePrimary: BrandColors.forest,
    ),
    brightness: Brightness.dark,

    // AppBar
    appBarTheme: AppBarTheme(
      backgroundColor: BrandColors.nightSurface,
      foregroundColor: BrandColors.nightText,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.titleLarge,
        fontWeight: FontWeight.w600,
        color: BrandColors.nightText,
        letterSpacing: TypographyTokens.letterSpacingTight,
      ),
      iconTheme: const IconThemeData(
        color: BrandColors.nightText,
        size: 22,
      ),
    ),

    // Text theme
    textTheme: _buildTextTheme(BrandColors.nightText),

    // Bottom Navigation
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: BrandColors.nightSurface,
      selectedItemColor: BrandColors.nightForest,
      unselectedItemColor: BrandColors.nightTextSecondary,
      selectedLabelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.normal,
      ),
      type: BottomNavigationBarType.fixed,
      elevation: Elevation.low,
    ),

    // FAB
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: BrandColors.nightForest,
      foregroundColor: BrandColors.nightSurface,
      elevation: Elevation.medium,
      highlightElevation: Elevation.high,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    ),

    // Cards
    cardTheme: CardThemeData(
      elevation: Elevation.low,
      color: BrandColors.nightSurfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      margin: EdgeInsets.zero,
    ),

    // Dialogs
    dialogTheme: DialogThemeData(
      backgroundColor: BrandColors.nightSurfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: Elevation.high,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      titleTextStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.headlineMedium,
        fontWeight: FontWeight.w600,
        color: BrandColors.nightText,
      ),
    ),

    // Buttons
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: BrandColors.nightForest,
        foregroundColor: BrandColors.nightSurface,
        elevation: Elevation.low,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: Spacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BrandColors.nightForest,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: Spacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        side: const BorderSide(color: BrandColors.nightForest, width: 1.5),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: BrandColors.nightForest,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.sm,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: TypographyTokens.labelLarge,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),

    // Input decoration
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BrandColors.nightSurfaceElevated,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: Color(0xFF3A3836)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: Color(0xFF3A3836)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: BrandColors.nightForest, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: Color(0xFFE8A090)),
      ),
      hintStyle: GoogleFonts.inter(
        color: BrandColors.nightTextSecondary,
        fontSize: TypographyTokens.bodyMedium,
      ),
    ),

    // Snackbar
    snackBarTheme: SnackBarThemeData(
      backgroundColor: BrandColors.nightSurfaceElevated,
      contentTextStyle: GoogleFonts.inter(
        color: BrandColors.nightText,
        fontSize: TypographyTokens.bodyMedium,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // Divider
    dividerTheme: const DividerThemeData(
      color: Color(0xFF3A3836),
      thickness: 1,
      space: 1,
    ),

    // Chip
    chipTheme: ChipThemeData(
      backgroundColor: BrandColors.forestDeep,
      labelStyle: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.w500,
        color: BrandColors.nightForest,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    ),

    // Progress indicator
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: BrandColors.nightTurquoise,
      linearTrackColor: Color(0xFF3A3836),
      circularTrackColor: Color(0xFF3A3836),
    ),

    // Icon theme
    iconTheme: const IconThemeData(
      color: BrandColors.nightText,
      size: 24,
    ),

    // List tile
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
  );

  /// Build text theme using Inter font
  static TextTheme _buildTextTheme(Color textColor) {
    return TextTheme(
      displayLarge: GoogleFonts.inter(
        fontSize: TypographyTokens.displayLarge,
        fontWeight: FontWeight.w300,
        color: textColor,
        letterSpacing: TypographyTokens.letterSpacingTight,
        height: TypographyTokens.lineHeightTight,
      ),
      displayMedium: GoogleFonts.inter(
        fontSize: TypographyTokens.displayMedium,
        fontWeight: FontWeight.w300,
        color: textColor,
        letterSpacing: TypographyTokens.letterSpacingTight,
        height: TypographyTokens.lineHeightTight,
      ),
      displaySmall: GoogleFonts.inter(
        fontSize: TypographyTokens.displaySmall,
        fontWeight: FontWeight.w400,
        color: textColor,
        letterSpacing: TypographyTokens.letterSpacingTight,
        height: TypographyTokens.lineHeightTight,
      ),
      headlineLarge: GoogleFonts.inter(
        fontSize: TypographyTokens.headlineLarge,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: TypographyTokens.lineHeightTight,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: TypographyTokens.headlineMedium,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: TypographyTokens.lineHeightTight,
      ),
      headlineSmall: GoogleFonts.inter(
        fontSize: TypographyTokens.headlineSmall,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: TypographyTokens.lineHeightNormal,
      ),
      titleLarge: GoogleFonts.inter(
        fontSize: TypographyTokens.titleLarge,
        fontWeight: FontWeight.w600,
        color: textColor,
        height: TypographyTokens.lineHeightNormal,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: TypographyTokens.titleMedium,
        fontWeight: FontWeight.w500,
        color: textColor,
        height: TypographyTokens.lineHeightNormal,
      ),
      titleSmall: GoogleFonts.inter(
        fontSize: TypographyTokens.titleSmall,
        fontWeight: FontWeight.w500,
        color: textColor,
        height: TypographyTokens.lineHeightNormal,
      ),
      labelLarge: GoogleFonts.inter(
        fontSize: TypographyTokens.labelLarge,
        fontWeight: FontWeight.w500,
        color: textColor,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: TypographyTokens.labelMedium,
        fontWeight: FontWeight.w500,
        color: textColor,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: TypographyTokens.labelSmall,
        fontWeight: FontWeight.w500,
        color: textColor,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: TypographyTokens.bodyLarge,
        fontWeight: FontWeight.normal,
        color: textColor,
        height: TypographyTokens.lineHeightRelaxed,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: TypographyTokens.bodyMedium,
        fontWeight: FontWeight.normal,
        color: textColor,
        height: TypographyTokens.lineHeightRelaxed,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: TypographyTokens.bodySmall,
        fontWeight: FontWeight.normal,
        color: textColor,
        height: TypographyTokens.lineHeightRelaxed,
      ),
    );
  }
}

// =============================================================================
// Legacy Compatibility - Keep old AppColors for gradual migration
// =============================================================================

/// @deprecated Use BrandColors from design_tokens.dart instead
/// Kept for backwards compatibility during migration
class AppColors {
  // Light Mode Colors - mapped to new brand colors
  static const lightPrimary = BrandColors.forest;
  static const lightOnPrimary = BrandColors.softWhite;
  static const lightPrimaryContainer = BrandColors.forestMist;
  static const lightOnPrimaryContainer = BrandColors.forestDeep;
  static const lightSecondary = BrandColors.turquoise;
  static const lightOnSecondary = BrandColors.softWhite;
  static const lightTertiary = BrandColors.warning;
  static const lightOnTertiary = BrandColors.softWhite;
  static const lightError = BrandColors.error;
  static const lightOnError = BrandColors.softWhite;
  static const lightErrorContainer = BrandColors.errorLight;
  static const lightOnErrorContainer = BrandColors.error;
  static const lightInversePrimary = BrandColors.nightForest;
  static const lightShadow = BrandColors.charcoal;
  static const lightSurface = BrandColors.cream;
  static const lightOnSurface = BrandColors.charcoal;
  static const lightAppBarBackground = BrandColors.cream;

  // Dark Mode Colors - mapped to new brand colors
  static const darkPrimary = BrandColors.nightForest;
  static const darkOnPrimary = BrandColors.nightSurface;
  static const darkPrimaryContainer = BrandColors.forestDeep;
  static const darkOnPrimaryContainer = BrandColors.nightForest;
  static const darkSecondary = BrandColors.nightTurquoise;
  static const darkOnSecondary = BrandColors.nightSurface;
  static const darkTertiary = BrandColors.warning;
  static const darkOnTertiary = BrandColors.nightSurface;
  static const darkError = Color(0xFFE8A090);
  static const darkOnError = BrandColors.nightSurface;
  static const darkErrorContainer = Color(0xFF5A3A34);
  static const darkOnErrorContainer = Color(0xFFE8A090);
  static const darkInversePrimary = BrandColors.forest;
  static const darkShadow = Colors.black;
  static const darkSurface = BrandColors.nightSurface;
  static const darkOnSurface = BrandColors.nightText;
  static const darkAppBarBackground = BrandColors.nightSurface;
}

/// @deprecated Use TypographyTokens from design_tokens.dart instead
class AppFontSizes {
  static const double displayLarge = TypographyTokens.displayLarge;
  static const double displayMedium = TypographyTokens.displayMedium;
  static const double displaySmall = TypographyTokens.displaySmall;
  static const double headlineLarge = TypographyTokens.headlineLarge;
  static const double headlineMedium = TypographyTokens.headlineMedium;
  static const double headlineSmall = TypographyTokens.headlineSmall;
  static const double titleLarge = TypographyTokens.titleLarge;
  static const double titleMedium = TypographyTokens.titleMedium;
  static const double titleSmall = TypographyTokens.titleSmall;
  static const double labelLarge = TypographyTokens.labelLarge;
  static const double labelMedium = TypographyTokens.labelMedium;
  static const double labelSmall = TypographyTokens.labelSmall;
  static const double bodyLarge = TypographyTokens.bodyLarge;
  static const double bodyMedium = TypographyTokens.bodyMedium;
  static const double bodySmall = TypographyTokens.bodySmall;
}
