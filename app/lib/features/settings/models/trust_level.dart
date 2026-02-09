import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Trust level for agent execution, matching server TrustLevel enum.
///
/// Binary model: trusted (bare metal) or untrusted (Docker sandbox).
enum TrustLevel {
  trusted,
  untrusted;

  String get displayName => switch (this) {
        trusted => 'Trusted',
        untrusted => 'Untrusted',
      };

  String get description => switch (this) {
        trusted => 'Full access to tools and vault files',
        untrusted => 'Runs in isolated Docker container',
      };

  IconData get icon => switch (this) {
        trusted => Icons.shield_outlined,
        untrusted => Icons.security_outlined,
      };

  Color iconColor(bool isDark) => switch (this) {
        trusted => isDark ? BrandColors.nightForest : BrandColors.forest,
        untrusted => Colors.blue,
      };

  static TrustLevel fromString(String? value) {
    if (value == null) return TrustLevel.trusted;
    // Legacy mapping: full/vault → trusted, sandboxed → untrusted
    const legacy = {
      'full': 'trusted',
      'vault': 'trusted',
      'sandboxed': 'untrusted',
    };
    final mapped = legacy[value] ?? value;
    return TrustLevel.values.firstWhere(
      (e) => e.name == mapped,
      orElse: () => TrustLevel.trusted,
    );
  }
}
