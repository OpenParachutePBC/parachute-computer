import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_schema.dart';
import '../providers/brain_providers.dart';
import '../widgets/brain_field_widget.dart';
import 'brain_entity_form_screen.dart';

/// Entity detail screen showing all fields and relationships.
///
/// When [embedded] is true, rendered without Scaffold/AppBar as an inline
/// detail pane in the wide layout. [onDeleted] is called instead of
/// Navigator.pop() when the entity is deleted in embedded mode.
class BrainEntityDetailScreen extends ConsumerWidget {
  final String entityId;
  final BrainSchema? schema; // Null when navigating from relationship chip
  final bool embedded;
  final VoidCallback? onDeleted;

  const BrainEntityDetailScreen({
    required this.entityId,
    this.schema,
    this.embedded = false,
    this.onDeleted,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entityAsync = ref.watch(brainEntityDetailProvider(entityId));
    final schemasAsync = ref.watch(brainSchemaListProvider);

    final content = entityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text(
                'Failed to load entity',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Go Back'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      ref.invalidate(brainEntityDetailProvider(entityId));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ],
          ),
        ),
        data: (entity) {
          if (entity == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.search_off,
                    size: 64,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Entity not found',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    entityId,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }

          // Get schema for this entity type
          final schemas = schemasAsync.valueOrNull ?? [];
          final entitySchema = schema ??
              (schemas.isNotEmpty
                  ? schemas.firstWhere(
                      (s) => s.name == entity.type,
                      orElse: () => schemas.first,
                    )
                  : null);

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                title: Text(
                  entity.displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                backgroundColor:
                    isDark ? BrandColors.nightSurface : BrandColors.softWhite,
                elevation: 0,
                pinned: true,
                // In embedded mode, show a close button instead of back button
                leading: embedded
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: onDeleted, // closes the detail pane
                        tooltip: 'Close',
                      )
                    : null,
                automaticallyImplyLeading: !embedded,
                actions: [
                  // Edit button
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => BrainEntityFormScreen(
                            entityType: entity.type,
                            entityId: entityId,
                          ),
                        ),
                      );
                    },
                    tooltip: 'Edit',
                  ),
                  // Delete button
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _showDeleteConfirmation(context, ref),
                    tooltip: 'Delete',
                  ),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // Entity type badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? BrandColors.nightForest.withOpacity(0.3)
                            : BrandColors.forest.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.label_outline,
                            size: 16,
                            color: isDark
                                ? BrandColors.nightForest
                                : BrandColors.forest,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            entity.type,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isDark
                                  ? BrandColors.nightForest
                                  : BrandColors.forest,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Entity fields — use crystallized schema if defined,
                    // otherwise show all non-empty fields directly (open ontology).
                    if (entitySchema != null && entitySchema.fields.isNotEmpty)
                      ...entitySchema.fields.map((field) {
                        final value = entity[field.name];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    field.name,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? BrandColors.nightTextSecondary
                                          : BrandColors.driftwood,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  if (field.required) ...[
                                    const SizedBox(width: 4),
                                    Text(
                                      '*',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isDark
                                            ? Colors.red.shade400
                                            : Colors.red.shade700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              BrainFieldWidget(field: field, value: value),
                            ],
                          ),
                        );
                      })
                    else
                      // No crystallized schema — show all non-empty fields as plain text
                      ...entity.fields.entries
                          .where((e) => e.value != null && e.value.toString().isNotEmpty)
                          .map((entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.key,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? BrandColors.nightTextSecondary
                                        : BrandColors.driftwood,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SelectableText(
                                  entry.value.toString(),
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: isDark
                                        ? BrandColors.nightText
                                        : BrandColors.charcoal,
                                  ),
                                ),
                              ],
                            ),
                          )),

                    // Tags section
                    if (entity.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'TAGS',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: entity.tags.map((tag) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
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
                                fontSize: 13,
                                color: isDark
                                    ? BrandColors.nightForest
                                    : BrandColors.forest,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],

                    const SizedBox(height: 32),

                    // Entity ID (technical detail)
                    Text(
                      'ENTITY ID',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      entity.id,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),

                    const SizedBox(height: 80),
                  ]),
                ),
              ),
            ],
          );
        },
      );

    // In embedded mode, don't add an outer Scaffold (the detail pane is
    // already inside the wide-layout Scaffold).
    if (embedded) {
      return ColoredBox(
        color: Theme.of(context).brightness == Brightness.dark
            ? BrandColors.nightSurface
            : BrandColors.cream,
        child: content,
      );
    }
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? BrandColors.nightSurface
          : BrandColors.cream,
      body: content,
    );
  }

  Future<void> _showDeleteConfirmation(BuildContext context, WidgetRef ref) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entity'),
        content: Text(
          'Are you sure you want to delete this entity? This action cannot be undone.',
          style: TextStyle(
            color: isDark
                ? BrandColors.nightTextSecondary
                : BrandColors.driftwood,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final service = ref.read(brainServiceProvider);
        await service.deleteEntity(entityId, commitMsg: 'Delete entity via UI');

        // Invalidate providers to refresh lists
        ref.invalidate(brainEntityListProvider);
        ref.invalidate(brainEntityDetailProvider(entityId));

        if (context.mounted) {
          if (embedded && onDeleted != null) {
            onDeleted!(); // Clear selected entity in wide pane
          } else {
            navigator.pop(); // Return to list on mobile
          }
          messenger.showSnackBar(
            const SnackBar(content: Text('Entity deleted successfully')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('Failed to delete entity: $e')),
          );
        }
      }
    }
  }
}
