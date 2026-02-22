import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';
import 'brain_entity_list_screen.dart';
import 'brain_entity_form_screen.dart';

/// Brain home screen with entity type tabs.
class BrainHomeScreen extends ConsumerStatefulWidget {
  const BrainHomeScreen({super.key});

  @override
  ConsumerState<BrainHomeScreen> createState() => _BrainHomeScreenState();
}

class _BrainHomeScreenState extends ConsumerState<BrainHomeScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  void _onTabChanged() {
    if (_tabController != null && _tabController!.indexIsChanging) {
      final schemasAsync = ref.read(brainSchemaListProvider);
      schemasAsync.whenData((schemas) {
        if (_tabController!.index < schemas.length) {
          final schema = schemas[_tabController!.index];
          ref.read(brainSelectedTypeProvider.notifier).state = schema.name;
        }
      });
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChanged);
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final schemasAsync = ref.watch(brainSchemaListProvider);

    return schemasAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(
          title: const Text('Brain'),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(
          title: const Text('Brain'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text(
                'Failed to load schemas',
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
              ElevatedButton(
                onPressed: () => ref.invalidate(brainSchemaListProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (schemas) {
        if (schemas.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: Text(
                'Brain',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              backgroundColor:
                  isDark ? BrandColors.nightSurface : BrandColors.softWhite,
            ),
            backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.schema_outlined,
                    size: 64,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No schemas found',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create schema YAML files in ~/Parachute/.brain/schemas/',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        // Initialize tab controller when schemas are available
        if (_tabController == null ||
            _tabController!.length != schemas.length) {
          _tabController?.removeListener(_onTabChanged);
          _tabController?.dispose();
          _tabController = TabController(length: schemas.length, vsync: this);
          _tabController!.addListener(_onTabChanged);

          // Set initial selected type
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref.read(brainSelectedTypeProvider.notifier).state =
                  schemas.first.name;
            }
          });
        }

        final selectedType = ref.watch(brainSelectedTypeProvider);

        return Scaffold(
          appBar: AppBar(
            title: Text(
              'Brain',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            backgroundColor:
                isDark ? BrandColors.nightSurface : BrandColors.softWhite,
            elevation: 0,
            bottom: TabBar(
              controller: _tabController,
              labelColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              unselectedLabelColor:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              indicatorColor:
                  isDark ? BrandColors.nightForest : BrandColors.forest,
              tabs: schemas.map((schema) => Tab(text: schema.name)).toList(),
            ),
          ),
          backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
          body: TabBarView(
            controller: _tabController,
            children: schemas
                .map((schema) => BrainEntityListScreen(
                      entityType: schema.name,
                      schema: schema,
                    ))
                .toList(),
          ),
          floatingActionButton: selectedType != null
              ? FloatingActionButton.extended(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => BrainEntityFormScreen(
                          entityType: selectedType,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: Text('Create $selectedType'),
                  backgroundColor:
                      isDark ? BrandColors.nightForest : BrandColors.forest,
                  foregroundColor: Colors.white,
                )
              : null,
        );
      },
    );
  }
}
