import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Trust level for agent execution, matching server TrustLevel enum.
///
/// Binary model: direct (bare metal) or sandboxed (Docker sandbox).
enum TrustLevel {
  direct,
  sandboxed;

  String get displayName => switch (this) {
        direct => 'Direct',
        sandboxed => 'Sandboxed',
      };

  String get description => switch (this) {
        direct => 'Full access to tools and vault files',
        sandboxed => 'Runs in isolated Docker container',
      };

  IconData get icon => switch (this) {
        direct => Icons.shield_outlined,
        sandboxed => Icons.security_outlined,
      };

  Color iconColor(bool isDark) => switch (this) {
        direct => isDark ? BrandColors.nightForest : BrandColors.forest,
        sandboxed => Colors.blue,
      };

  static TrustLevel fromString(String? value) {
    if (value == null) return TrustLevel.direct;
    // Legacy mapping: full/vault/trusted → direct, untrusted → sandboxed
    const legacy = {
      'full': 'direct',
      'vault': 'direct',
      'trusted': 'direct',
      'untrusted': 'sandboxed',
    };
    final mapped = legacy[value] ?? value;
    return TrustLevel.values.firstWhere(
      (e) => e.name == mapped,
      orElse: () => TrustLevel.direct,
    );
  }
}
