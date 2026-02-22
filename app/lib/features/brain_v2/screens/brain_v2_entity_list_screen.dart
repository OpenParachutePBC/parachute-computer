import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_v2_schema.dart';
import '../providers/brain_v2_providers.dart';
import '../widgets/brain_v2_entity_card.dart';
import 'brain_v2_entity_detail_screen.dart';

/// Entity list screen for a specific entity type.
class BrainV2EntityListScreen extends ConsumerStatefulWidget {
  final String entityType;
  final BrainV2Schema schema;

  const BrainV2EntityListScreen({
    required this.entityType,
    required this.schema,
    super.key,
  });

  @override
  ConsumerState<BrainV2EntityListScreen> createState() =>
      _BrainV2EntityListScreenState();
}

class _BrainV2EntityListScreenState
    extends ConsumerState<BrainV2EntityListScreen> {
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
      ref.read(brainV2SearchQueryProvider.notifier).state =
          _searchController.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entitiesAsync = ref.watch(brainV2EntityListProvider(widget.entityType));
    final searchQuery = ref.watch(brainV2SearchQueryProvider);

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
                        ref.read(brainV2SearchQueryProvider.notifier).state = '';
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
                      ref.invalidate(brainV2EntityListProvider(widget.entityType));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
            data: (entities) {
              // Filter entities by search query
              final filteredEntities = searchQuery.isEmpty
                  ? entities
                  : entities.where((entity) {
                      final name = entity.displayName.toLowerCase();
                      final query = searchQuery.toLowerCase();

                      // Search in name
                      if (name.contains(query)) return true;

                      // Search in tags
                      if (entity.tags.any((tag) => tag.toLowerCase().contains(query))) {
                        return true;
                      }

                      // Search in field values
                      return entity.fields.values.any((value) {
                        if (value == null) return false;
                        return value.toString().toLowerCase().contains(query);
                      });
                    }).toList();

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
                  ref.invalidate(brainV2EntityListProvider(widget.entityType));
                  await ref.read(brainV2EntityListProvider(widget.entityType).future);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: filteredEntities.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 0),
                  itemBuilder: (context, index) {
                    final entity = filteredEntities[index];
                    return BrainV2EntityCard(
                      entity: entity,
                      schema: widget.schema,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => BrainV2EntityDetailScreen(
                              entityId: entity.id,
                              schema: widget.schema,
                            ),
                          ),
                        );
                      },
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
