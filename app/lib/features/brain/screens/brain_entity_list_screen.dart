import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_entity.dart';
import '../models/brain_filter.dart';
import '../models/brain_schema.dart';
import '../providers/brain_providers.dart';
import '../widgets/brain_entity_card.dart';
import '../widgets/brain_query_bar.dart';
import 'brain_entity_detail_screen.dart';

/// Entity list screen for a specific entity type.
///
/// Used both as a standalone screen (mobile) and as an embedded panel
/// in the wide-layout split view.
class BrainEntityListScreen extends ConsumerStatefulWidget {
  final String entityType;
  final BrainSchema? schema;

  const BrainEntityListScreen({
    required this.entityType,
    this.schema,
    super.key,
  });

  @override
  ConsumerState<BrainEntityListScreen> createState() =>
      _BrainEntityListScreenState();
}

class _BrainEntityListScreenState
    extends ConsumerState<BrainEntityListScreen> {
  Timer? _debounce;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(brainSearchQueryProvider.notifier).state =
          _searchController.text;
    });
  }

  void _onEntityTap(BuildContext context, WidgetRef ref, BrainEntity entity) {
    final mode = ref.read(brainLayoutModeProvider);
    if (mode == BrainLayoutMode.wide) {
      ref.read(brainSelectedEntityProvider.notifier).state = entity.id;
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BrainEntityDetailScreen(
            entityId: entity.id,
            schema: widget.schema,
          ),
        ),
      );
    }
  }

  bool _matchesFilters(BrainEntity entity, List<BrainFilterCondition> filters) {
    for (final condition in filters) {
      final fieldValue = entity.fields[condition.fieldName];
      final rawValue = fieldValue?.toString() ?? '';

      final condValue = switch (condition.value) {
        StringFilterValue v => v.value,
        EnumFilterValue v => v.value,
        LinkFilterValue v => v.entityId,
        IntFilterValue v => v.value.toString(),
      };

      final matches = switch (condition.operator) {
        'eq' => rawValue == condValue,
        'neq' => rawValue != condValue,
        'contains' => rawValue.toLowerCase().contains(condValue.toLowerCase()),
        _ => true,
      };
      if (!matches) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entitiesAsync = ref.watch(brainEntityListProvider(widget.entityType));
    final searchQuery = ref.watch(brainSearchQueryProvider);
    final activeFilters = ref.watch(brainActiveFiltersProvider);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search ${widget.entityType}...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        ref.read(brainSearchQueryProvider.notifier).state = '';
                      },
                    )
                  : null,
              filled: true,
              fillColor: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),

        // Query filter bar (shown when schema has fields)
        BrainQueryBar(schema: widget.schema),

        // Entity list
        Expanded(
          child: entitiesAsync.when(
            loading: () => const Center(
              child: CircularProgressIndicator(),
            ),
            error: (error, stack) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                  const SizedBox(height: 16),
                  Text(
                    'Failed to load entities',
                    style: TextStyle(
                      fontSize: 16,
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
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      ref.invalidate(brainEntityListProvider(widget.entityType));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
            data: (entities) {
              // Apply text search filter
              var filteredEntities = searchQuery.isEmpty
                  ? entities
                  : entities.where((entity) {
                      final name = entity.displayName.toLowerCase();
                      final query = searchQuery.toLowerCase();
                      if (name.contains(query)) return true;
                      if (entity.tags.any((tag) => tag.toLowerCase().contains(query))) return true;
                      return entity.fields.values.any((value) {
                        if (value == null) return false;
                        return value.toString().toLowerCase().contains(query);
                      });
                    }).toList();

              // Apply active filter conditions (client-side).
              // O(N * filters) — safe at limit=100 (current cap).
              // Move to server-side WOQL WHERE if limit exceeds 500.
              if (activeFilters.isNotEmpty) {
                filteredEntities = filteredEntities
                    .where((e) => _matchesFilters(e, activeFilters))
                    .toList();
              }

              if (filteredEntities.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        searchQuery.isEmpty ? Icons.inbox_outlined : Icons.search_off,
                        size: 64,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        searchQuery.isEmpty
                            ? 'No ${widget.entityType} entities yet'
                            : 'No results found',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                      if (searchQuery.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Tap the + button to create your first ${widget.entityType}',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(brainEntityListProvider(widget.entityType));
                  await ref.read(brainEntityListProvider(widget.entityType).future);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: filteredEntities.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 0),
                  itemBuilder: (context, index) {
                    final entity = filteredEntities[index];
                    return BrainEntityCard(
                      entity: entity,
                      schema: widget.schema ??
                          BrainSchema(
                            id: widget.entityType,
                            name: widget.entityType,
                          ),
                      onTap: () => _onEntityTap(context, ref, entity),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
