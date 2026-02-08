import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Trust level for agent execution, matching server TrustLevel enum.
enum TrustLevel {
  full,
  vault,
  sandboxed;

  String get displayName => switch (this) {
        full => 'Full Access',
        vault => 'Vault Only',
        sandboxed => 'Isolated',
      };

  String get description => switch (this) {
        full => 'Unrestricted access to all tools and files',
        vault => 'Read vault files only, no commands',
        sandboxed => 'Runs in separate workspace with chosen access',
      };

  IconData get icon => switch (this) {
        full => Icons.shield_outlined,
        vault => Icons.lock_outlined,
        sandboxed => Icons.security_outlined,
      };

  Color iconColor(bool isDark) => switch (this) {
        full => isDark ? BrandColors.nightForest : BrandColors.forest,
        vault => Colors.amber,
        sandboxed => Colors.blue,
      };

  static TrustLevel fromString(String? value) {
    if (value == null) return TrustLevel.full;
    return TrustLevel.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TrustLevel.full,
    );
  }
}
