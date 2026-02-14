import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';
import '../widgets/brain_entity_card.dart';
import 'brain_entity_screen.dart';

/// Main Brain tab screen with search and results.
class BrainScreen extends ConsumerStatefulWidget {
  const BrainScreen({super.key});

  @override
  ConsumerState<BrainScreen> createState() => _BrainScreenState();
}

class _BrainScreenState extends ConsumerState<BrainScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(brainSearchQueryProvider.notifier).state = query;
    });
  }

  Future<void> _reload() async {
    final service = ref.read(brainServiceProvider);
    if (service == null) return;

    try {
      await service.reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Brain index reloaded'),
            backgroundColor: BrandColors.forest,
          ),
        );
      }
      // Refresh search results
      ref.invalidate(brainSearchResultsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reload failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final searchResults = ref.watch(brainSearchResultsProvider);
    final query = ref.watch(brainSearchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Brain',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            tooltip: 'Reload brain index',
            onPressed: _reload,
          ),
        ],
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search entities...',
                prefixIcon: Icon(
                  Icons.search,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
                suffixIcon: query.isNotEmpty
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
                    : Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide(
                    color: isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.3) : BrandColors.stone,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide(
                    color: isDark
                        ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                        : BrandColors.stone.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide(
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ),
            ),
          ),
          // Results
          Expanded(
            child: _buildContent(isDark, searchResults, query),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isDark, AsyncValue searchResults, String query) {
    if (query.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 64,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            SizedBox(height: Spacing.md),
            Text(
              'Search your Brain',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w500,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              'Find people, projects, concepts, and more',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ],
        ),
      );
    }

    return searchResults.when(
      data: (result) {
        if (result == null || result.results.isEmpty) {
          return Center(
            child: Text(
              'No results for "$query"',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          );
        }

        return ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: Spacing.md),
          itemCount: result.results.length,
          separatorBuilder: (_, __) => SizedBox(height: Spacing.sm),
          itemBuilder: (context, index) {
            final entity = result.results[index];
            return BrainEntityCard(
              entity: entity,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BrainEntityScreen(
                      paraId: entity.paraId,
                      name: entity.name,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: EdgeInsets.all(Spacing.lg),
          child: Text(
            'Error: $error',
            style: TextStyle(
              color: BrandColors.error,
              fontSize: TypographyTokens.bodyMedium,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
