import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_schema.dart';
import '../providers/brain_providers.dart';
import '../providers/brain_ui_state_provider.dart';
import 'brain_type_manager_sheet.dart';

/// Left sidebar panel showing all schema types with entity counts.
///
/// - Tap → select type (updates brainSelectedTypeProvider)
/// - Long-press → opens BrainTypeManagerSheet in edit mode
/// - "+ New Type" button → opens BrainTypeManagerSheet in create mode
///
/// Uses per-row select() for O(1) rebuild on type switch.
class BrainTypeSidebar extends ConsumerWidget {
  /// Called when a type is tapped (e.g., to close Drawer on mobile).
  final VoidCallback? onTypeTap;

  const BrainTypeSidebar({this.onTypeTap, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typesAsync = ref.watch(brainSchemaDetailProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Types',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),

        // Type list
        Expanded(
          child: typesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Failed to load types',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            data: (types) {
              if (types.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No types yet',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: types.length,
                itemBuilder: (context, i) => _TypeRow(
                  schema: types[i],
                  onTap: onTypeTap,
                ),
              );
            },
          ),
        ),

        // Divider
        Divider(
          height: 1,
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
              : BrandColors.charcoal.withValues(alpha: 0.1),
        ),

        // + New Type button
        InkWell(
          onTap: () => _openNewTypeSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.add,
                  size: 16,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: 8),
                Text(
                  'New Type',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openNewTypeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BrainTypeManagerSheet(typeName: null),
    );
  }
}

/// Individual type row — uses select() for O(1) rebuild on selection change.
class _TypeRow extends ConsumerWidget {
  final BrainSchemaDetail schema;
  final VoidCallback? onTap;

  const _TypeRow({required this.schema, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = ref.watch(
      brainSelectedTypeProvider.select((t) => t == schema.name),
    );

    return InkWell(
      onTap: () {
        ref.read(brainSelectedTypeProvider.notifier).state = schema.name;
        // Clear entity selection and search when switching types (filters auto-clear via BrainFilterNotifier)
        ref.read(brainSelectedEntityProvider.notifier).state = null;
        ref.read(brainSearchQueryProvider.notifier).state = '';
        onTap?.call();
      },
      onLongPress: () => _openEditSheet(context),
      child: Container(
        color: isSelected
            ? (isDark
                ? BrandColors.nightForest.withValues(alpha: 0.2)
                : BrandColors.forestMist)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                schema.name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                      : (isDark ? BrandColors.nightText : BrandColors.charcoal),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              schema.entityCount >= 0 ? '${schema.entityCount}' : '—',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openEditSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BrainTypeManagerSheet(typeName: schema.name),
    );
  }
}
