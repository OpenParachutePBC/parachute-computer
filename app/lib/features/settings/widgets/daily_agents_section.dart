import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/daily/journal/screens/caller_management_screen.dart';

/// Daily agents settings section — links to the full CallerManagementScreen.
class DailyAgentsSection extends ConsumerWidget {
  const DailyAgentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Daily Agents',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Manage your daily agents — schedule, run, and configure Callers.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.md),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CallerManagementScreen(),
              ),
            ),
            borderRadius: Radii.button,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.md,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.cream,
                borderRadius: Radii.button,
                border: Border.all(
                  color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                      .withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.tune,
                    size: 20,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      'Manage Daily Agents',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        fontWeight: FontWeight.w500,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: BrandColors.driftwood,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
