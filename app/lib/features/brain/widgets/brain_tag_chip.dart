import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Small chip for displaying a Brain entity tag.
class BrainTagChip extends StatelessWidget {
  final String tag;

  const BrainTagChip({super.key, required this.tag});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xxs,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.2)
            : BrandColors.forestMist,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: TypographyTokens.labelSmall,
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
