import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';
import '../screens/brain_entity_detail_screen.dart';

/// Clickable chip for entity relationships.
///
/// Displays entity name and navigates to detail on tap.
class BrainRelationshipChip extends ConsumerWidget {
  final String entityId; // Entity IRI (e.g., "Person/Alice")

  const BrainRelationshipChip({
    required this.entityId,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entityAsync = ref.watch(brainEntityDetailProvider(entityId));

    return entityAsync.when(
      loading: () => _buildChip(
        context,
        _extractNameFromId(entityId),
        isDark,
        isLoading: true,
      ),
      error: (error, stack) => _buildChip(
        context,
        _extractNameFromId(entityId),
        isDark,
        isError: true,
      ),
      data: (entity) {
        final name = entity?.displayName ?? _extractNameFromId(entityId);
        final type = entity?.type;

        return _buildChip(
          context,
          name,
          isDark,
          type: type,
          onTap: entity != null
              ? () {
                  // Navigate to entity detail
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => BrainEntityDetailScreen(
                        entityId: entityId,
                        schema: null, // Will load schema in detail screen
                      ),
                    ),
                  );
                }
              : null,
        );
      },
    );
  }

  Widget _buildChip(
    BuildContext context,
    String label,
    bool isDark, {
    String? type,
    bool isLoading = false,
    bool isError = false,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isError
              ? (isDark ? Colors.red.shade900.withOpacity(0.2) : Colors.red.shade50)
              : (isDark
                  ? BrandColors.nightForest.withOpacity(0.2)
                  : BrandColors.forest.withOpacity(0.1)),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: isError
                ? (isDark ? Colors.red.shade700 : Colors.red.shade300)
                : (isDark ? BrandColors.nightForest : BrandColors.forest),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              )
            else
              Icon(
                isError ? Icons.error_outline : Icons.link,
                size: 14,
                color: isError
                    ? (isDark ? Colors.red.shade400 : Colors.red.shade700)
                    : (isDark ? BrandColors.nightForest : BrandColors.forest),
              ),
            const SizedBox(width: 6),
            if (type != null) ...[
              Text(
                type,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '/',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isError
                    ? (isDark ? Colors.red.shade400 : Colors.red.shade700)
                    : (isDark ? BrandColors.nightForest : BrandColors.forest),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Extract name from entity IRI (e.g., "Person/Alice" -> "Alice").
  String _extractNameFromId(String id) {
    if (id.contains('/')) {
      return id.split('/').last;
    }
    return id;
  }
}
