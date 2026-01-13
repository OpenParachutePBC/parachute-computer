import 'package:flutter/material.dart';

/// Parachute Design Tokens
///
/// "Think naturally" - Technology that gives you space rather than demands attention.
///
/// This file defines the foundational design tokens for the Parachute brand.
/// All UI components should reference these tokens rather than hardcoded values.

// =============================================================================
// COLORS - Brand Palette
// =============================================================================

/// Core brand colors derived from nature
/// Keywords: Smoothness, balance, growth, connected, in tune with nature
class BrandColors {
  BrandColors._();

  // ---------------------------------------------------------------------------
  // Primary - Forest Green (Grounded, Natural, Trustworthy)
  // ---------------------------------------------------------------------------

  /// Primary brand color - a muted, earthy forest green
  /// Use for: Primary actions, brand presence, key UI elements
  static const Color forest = Color(0xFF40695B);

  /// Lighter variant for backgrounds and containers
  static const Color forestLight = Color(0xFF5A8577);

  /// Even lighter for subtle backgrounds
  static const Color forestMist = Color(0xFFD4E5DF);

  /// Darker variant for emphasis
  static const Color forestDeep = Color(0xFF2D4A40);

  // ---------------------------------------------------------------------------
  // Secondary - Turquoise (Flow, Clarity, Breath)
  // ---------------------------------------------------------------------------

  /// Secondary brand color - evokes water and flow
  /// Use for: Secondary actions, links, accent elements
  static const Color turquoise = Color(0xFF5EA8A7);

  /// Lighter variant
  static const Color turquoiseLight = Color(0xFF7FBFBE);

  /// Mist variant for backgrounds
  static const Color turquoiseMist = Color(0xFFD5ECEB);

  /// Deeper variant for emphasis
  static const Color turquoiseDeep = Color(0xFF3D8584);

  // ---------------------------------------------------------------------------
  // Neutrals - Warm, Soft Tones
  // ---------------------------------------------------------------------------

  /// Warm off-white for backgrounds - not clinical white
  static const Color cream = Color(0xFFFAF9F7);

  /// Soft white with warmth
  static const Color softWhite = Color(0xFFFFFEFC);

  /// Light warm gray
  static const Color stone = Color(0xFFE8E6E3);

  /// Medium warm gray for secondary text
  static const Color driftwood = Color(0xFF9B9590);

  /// Darker warm gray for primary text
  static const Color charcoal = Color(0xFF3D3A37);

  /// Deep charcoal for high contrast text
  static const Color ink = Color(0xFF1F1D1B);

  // ---------------------------------------------------------------------------
  // Semantic Colors - Gentle, Not Alarming
  // ---------------------------------------------------------------------------

  /// Success - Soft sage green (not harsh)
  static const Color success = Color(0xFF6B9B7A);
  static const Color successLight = Color(0xFFE3F0E7);

  /// Warning - Warm amber (inviting, not alarming)
  static const Color warning = Color(0xFFD4A056);
  static const Color warningLight = Color(0xFFFFF3E0);

  /// Error - Soft terracotta (serious but not aggressive)
  static const Color error = Color(0xFFB86B5A);
  static const Color errorLight = Color(0xFFFBEAE6);

  /// Info - Muted blue-gray
  static const Color info = Color(0xFF6B8BA8);
  static const Color infoLight = Color(0xFFE6EEF4);

  // ---------------------------------------------------------------------------
  // Dark Mode Variants
  // ---------------------------------------------------------------------------

  /// Dark mode surface - deep, warm dark (not pure black)
  static const Color nightSurface = Color(0xFF1A1917);

  /// Elevated dark surface
  static const Color nightSurfaceElevated = Color(0xFF262523);

  /// Dark mode primary - lighter forest for visibility
  static const Color nightForest = Color(0xFF7AB09D);

  /// Dark mode secondary - lighter turquoise
  static const Color nightTurquoise = Color(0xFF8CCFCE);

  /// Dark mode text - warm off-white
  static const Color nightText = Color(0xFFE8E5E1);

  /// Dark mode secondary text
  static const Color nightTextSecondary = Color(0xFFA09B95);
}

// =============================================================================
// SPACING - Breathing Room
// =============================================================================

/// Spacing tokens - generous, breathable layouts
/// The app should feel spacious, not cramped
class Spacing {
  Spacing._();

  /// Extra extra small - 2px (hairline gaps)
  static const double xxs = 2.0;

  /// Extra small - 4px (micro gaps)
  static const double xs = 4.0;

  /// Small - 8px (tight groupings)
  static const double sm = 8.0;

  /// Medium - 12px (standard gaps)
  static const double md = 12.0;

  /// Large - 16px (comfortable spacing)
  static const double lg = 16.0;

  /// Extra large - 24px (section dividers)
  static const double xl = 24.0;

  /// 2X large - 32px (major sections)
  static const double xxl = 32.0;

  /// 3X large - 48px (screen padding, hero areas)
  static const double xxxl = 48.0;

  /// Page padding - standard screen edge padding
  static const EdgeInsets pagePadding = EdgeInsets.all(lg);

  /// Card padding - internal card spacing
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);

  /// Compact card padding - for dense layouts
  static const EdgeInsets cardPaddingCompact = EdgeInsets.all(md);
}

// =============================================================================
// RADII - Soft, Organic Shapes
// =============================================================================

/// Border radius tokens - soft edges, pebble-like
/// "Think: pebbles, leaves, water ripples"
class Radii {
  Radii._();

  /// Small - 8px (badges, chips)
  static const double sm = 8.0;

  /// Medium - 12px (buttons, small cards)
  static const double md = 12.0;

  /// Large - 16px (cards, containers)
  static const double lg = 16.0;

  /// Extra large - 20px (dialogs, modals)
  static const double xl = 20.0;

  /// Full - for pills and circles
  static const double full = 999.0;

  /// Standard card radius
  static BorderRadius card = BorderRadius.circular(lg);

  /// Button radius
  static BorderRadius button = BorderRadius.circular(md);

  /// Badge/chip radius
  static BorderRadius badge = BorderRadius.circular(sm);

  /// Pill shape
  static BorderRadius pill = BorderRadius.circular(full);
}

// =============================================================================
// TYPOGRAPHY - Warm but Professional
// =============================================================================

/// Typography scale and weights
/// Keeping Inter for now, but with warmer application
class TypographyTokens {
  TypographyTokens._();

  // Font sizes
  static const double displayLarge = 48.0;
  static const double displayMedium = 36.0;
  static const double displaySmall = 28.0;

  static const double headlineLarge = 24.0;
  static const double headlineMedium = 20.0;
  static const double headlineSmall = 18.0;

  static const double titleLarge = 18.0;
  static const double titleMedium = 16.0;
  static const double titleSmall = 14.0;

  static const double bodyLarge = 16.0;
  static const double bodyMedium = 14.0;
  static const double bodySmall = 13.0;

  static const double labelLarge = 14.0;
  static const double labelMedium = 12.0;
  static const double labelSmall = 11.0;

  // Line heights - generous for readability
  static const double lineHeightTight = 1.2;
  static const double lineHeightNormal = 1.5;
  static const double lineHeightRelaxed = 1.7;

  // Letter spacing
  static const double letterSpacingTight = -0.5;
  static const double letterSpacingNormal = 0.0;
  static const double letterSpacingWide = 0.5;
}

// =============================================================================
// ELEVATION & SHADOWS - Subtle Depth
// =============================================================================

/// Elevation tokens - gentle, not harsh shadows
/// "Subtle depth, minimal shadows, focus on content hierarchy"
class Elevation {
  Elevation._();

  /// No elevation
  static const double none = 0.0;

  /// Low elevation - subtle lift (cards)
  static const double low = 1.0;

  /// Medium elevation - noticeable but soft (dialogs)
  static const double medium = 4.0;

  /// High elevation - prominent (FAB, modals)
  static const double high = 8.0;

  /// Soft shadow for cards - warm-tinted
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: BrandColors.charcoal.withValues(alpha: 0.06),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: BrandColors.charcoal.withValues(alpha: 0.04),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  /// Elevated shadow for floating elements
  static List<BoxShadow> elevatedShadow = [
    BoxShadow(
      color: BrandColors.charcoal.withValues(alpha: 0.1),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: BrandColors.charcoal.withValues(alpha: 0.05),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];
}

// =============================================================================
// ANIMATION - Gentle, Settling Motion
// =============================================================================

/// Animation tokens - "settling, not snapping"
/// Motion should feel like a deep breath
class Motion {
  Motion._();

  /// Quick - for micro-interactions (150ms)
  static const Duration quick = Duration(milliseconds: 150);

  /// Standard - for most transitions (250ms)
  static const Duration standard = Duration(milliseconds: 250);

  /// Gentle - for larger movements (350ms)
  static const Duration gentle = Duration(milliseconds: 350);

  /// Slow - for dramatic reveals (500ms)
  static const Duration slow = Duration(milliseconds: 500);

  /// Breathing - for ambient animations (4000ms)
  static const Duration breathing = Duration(milliseconds: 4000);

  /// Settling curve - eases gently into place
  static const Curve settling = Curves.easeOutCubic;

  /// Breathing curve - smooth in and out
  static const Curve breathe = Curves.easeInOut;

  /// Lift curve - for elements rising
  static const Curve lift = Curves.easeOutQuart;
}

// =============================================================================
// SEMANTIC TOKENS - UI State Colors
// =============================================================================

/// Semantic color tokens for specific UI states
/// These map brand colors to specific use cases
class SemanticColors {
  SemanticColors._();

  // Voice recording states
  static const Color voiceBadgeBackground = Color(0xFFD5ECEB); // turquoiseMist
  static const Color voiceBadgeForeground = Color(0xFF3D8584); // turquoiseDeep
  static const Color voiceBadgeBorder = Color(0xFF7FBFBE); // turquoiseLight

  // Omi device states
  static const Color omiBadgeBackground = Color(0xFFE8E0F0);
  static const Color omiBadgeForeground = Color(0xFF6B5B8A);
  static const Color omiBadgeBorder = Color(0xFFB8A8D0);

  // Context/tag states
  static const Color contextBadgeBackground = Color(0xFFD4E5DF); // forestMist
  static const Color contextBadgeForeground = Color(0xFF40695B); // forest
  static const Color contextBadgeBorder = Color(0xFF5A8577); // forestLight

  // Processing states
  static const Color processingBackground = BrandColors.warningLight;
  static const Color processingForeground = BrandColors.warning;
  static const Color processingBorder = Color(0xFFE8C088);

  // Error/orphaned states
  static const Color errorBackground = BrandColors.errorLight;
  static const Color errorForeground = BrandColors.error;
  static const Color errorBorder = Color(0xFFD49488);
}
