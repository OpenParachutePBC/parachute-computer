import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Compact empty state shown on today's journal when no agent cards exist.
///
/// Encourages the user to set up Callers (daily agents) via Settings.
class CardsEmptyState extends StatelessWidget {
  const CardsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
          borderRadius: Radii.card,
          border: Border.all(
            color: isDark
                ? BrandColors.charcoal.withValues(alpha: 0.4)
                : BrandColors.stone,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: BrandColors.forestMist.withValues(
                  alpha: isDark ? 0.15 : 1.0,
                ),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Icon(
                Icons.auto_awesome_outlined,
                size: 24,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
            SizedBox(width: Spacing.md + Spacing.xxs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Daily agents',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Set up a Caller to get reflections, content ideas, and more.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: Spacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
              style: TextButton.styleFrom(
                foregroundColor:
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: Radii.button,
                ),
              ),
              child: const Text('Set up'),
            ),
          ],
        ),
      ),
    );
  }
}
