import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_entity.dart';
import '../models/brain_schema.dart';

/// Card widget for displaying an entity in a list.
class BrainEntityCard extends StatelessWidget {
  final BrainEntity entity;
  final BrainSchema schema;
  final VoidCallback? onTap;

  const BrainEntityCard({
    required this.entity,
    required this.schema,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(
          color: isDark
              ? BrandColors.nightSurface
              : BrandColors.softWhite.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Entity name/title
              Text(
                entity.displayName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),

              // Show primary fields (first 2-3 non-array fields)
              ...schema.primaryFields.take(3).map((field) {
                final value = entity[field.name];
                if (value == null) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${field.name}: ${_formatValue(value)}',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }),

              // Tags
              if (entity.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: entity.tags.map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? BrandColors.nightForest.withOpacity(0.2)
                            : BrandColors.forest.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatValue(dynamic value) {
    if (value is List) {
      return value.take(3).join(', ') + (value.length > 3 ? '...' : '');
    }
    return value.toString();
  }
}
