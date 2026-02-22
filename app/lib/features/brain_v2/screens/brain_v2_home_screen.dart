import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_v2_providers.dart';
import 'brain_v2_entity_list_screen.dart';
import 'brain_v2_entity_form_screen.dart';

/// Brain v2 home screen with entity type tabs.
class BrainV2HomeScreen extends ConsumerStatefulWidget {
  const BrainV2HomeScreen({super.key});

  @override
  ConsumerState<BrainV2HomeScreen> createState() => _BrainV2HomeScreenState();
}

class _BrainV2HomeScreenState extends ConsumerState<BrainV2HomeScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final schemasAsync = ref.watch(brainV2SchemaListProvider);

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
                onPressed: () => ref.invalidate(brainV2SchemaListProvider),
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
          _tabController?.dispose();
          _tabController = TabController(length: schemas.length, vsync: this);
          _tabController!.addListener(() {
            if (_tabController!.indexIsChanging) {
              final schema = schemas[_tabController!.index];
              ref.read(brainV2SelectedTypeProvider.notifier).state =
                  schema.name;
            }
          });

          // Set initial selected type
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref.read(brainV2SelectedTypeProvider.notifier).state =
                  schemas.first.name;
            }
          });
        }

        final selectedType = ref.watch(brainV2SelectedTypeProvider);

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
                .map((schema) => BrainV2EntityListScreen(
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
                        builder: (context) => BrainV2EntityFormScreen(
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
