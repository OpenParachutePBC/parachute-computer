import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_entity.dart';
import 'brain_tag_chip.dart';

/// Card displaying a Brain entity search result.
class BrainEntityCard extends StatelessWidget {
  final BrainEntity entity;
  final VoidCallback? onTap;

  const BrainEntityCard({super.key, required this.entity, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.stone.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Entity name
            Text(
              entity.name,
              style: TextStyle(
                fontSize: TypographyTokens.bodyLarge,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
            ),
            // Tags
            if (entity.tags.isNotEmpty) ...[
              SizedBox(height: Spacing.xs),
              Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xxs,
                children: entity.tags
                    .map((tag) => BrainTagChip(tag: tag))
                    .toList(),
              ),
            ],
            // Snippet
            if (entity.snippet != null && entity.snippet!.isNotEmpty) ...[
              SizedBox(height: Spacing.sm),
              Text(
                entity.snippet!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
