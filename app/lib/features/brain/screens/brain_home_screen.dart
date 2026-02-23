import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';
import '../providers/brain_ui_state_provider.dart';
import '../widgets/brain_type_sidebar.dart';
import 'brain_entity_list_screen.dart';
import 'brain_entity_detail_screen.dart';
import 'brain_entity_form_screen.dart';

/// Brain home screen with adaptive sidebar + entity list + detail pane layout.
///
/// Wide (≥800px): [Sidebar | Entity list | Detail pane (AnimatedSize)]
/// Narrow: Scaffold with Drawer containing the sidebar
///
/// CRITICAL: LayoutBuilder callback only evaluates width breakpoint.
/// All entity/schema state reads are in _BrainWideLayout / _BrainMobileLayout
/// (const ConsumerWidgets) to avoid O(N) rebuild cascade on entity tap.
class BrainHomeScreen extends ConsumerWidget {
  const BrainHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ONLY layout decision here — no entity or schema state reads
        final mode = constraints.maxWidth >= 800
            ? BrainLayoutMode.wide
            : BrainLayoutMode.mobile;

        // Update layout mode after frame (avoid setState during build)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (ref.read(brainLayoutModeProvider) != mode) {
            ref.read(brainLayoutModeProvider.notifier).state = mode;
          }
        });

        return mode == BrainLayoutMode.wide
            ? const _BrainWideLayout()
            : const _BrainMobileLayout();
      },
    );
  }
}

/// Wide layout: sidebar + entity list + optional detail pane.
/// const ConsumerWidget — sidebar and list do NOT rebuild on entity tap.
class _BrainWideLayout extends ConsumerWidget {
  const _BrainWideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedEntityId = ref.watch(brainSelectedEntityProvider);
    final selectedType = ref.watch(brainSelectedTypeProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: SafeArea(
        child: Row(
          children: [
            // Left: type sidebar (fixed 180px)
            const SizedBox(
              width: 180,
              child: BrainTypeSidebar(),
            ),

            // Vertical divider
            VerticalDivider(
              width: 1,
              color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                  : BrandColors.charcoal.withValues(alpha: 0.1),
            ),

            // Center: entity list
            Expanded(
              child: selectedType != null
                  ? _BrainEntityListPanel(entityType: selectedType)
                  : Center(
                      child: Text(
                        'Select a type to view entities',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                    ),
            ),

            // Right: detail pane (AnimatedSize for smooth open/close)
            // AnimatedSize is correct here — not AnimatedContainer or conditional Row child
            if (selectedEntityId != null) ...[
              VerticalDivider(
                width: 1,
                color: isDark
                    ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                    : BrandColors.charcoal.withValues(alpha: 0.1),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width: 360,
                  child: BrainEntityDetailScreen(
                    entityId: selectedEntityId,
                    embedded: true,
                    onDeleted: () {
                      ref.read(brainSelectedEntityProvider.notifier).state = null;
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      floatingActionButton: selectedType != null
          ? FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BrainEntityFormScreen(entityType: selectedType),
                ),
              ),
              backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              foregroundColor: Colors.white,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

/// Mobile layout: standard Scaffold with Drawer containing the sidebar.
class _BrainMobileLayout extends ConsumerWidget {
  const _BrainMobileLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedType = ref.watch(brainSelectedTypeProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: Text(
          selectedType ?? 'Brain',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        child: BrainTypeSidebar(
          onTypeTap: () => Navigator.of(context).pop(), // close Drawer
        ),
      ),
      body: selectedType != null
          ? _BrainEntityListPanel(entityType: selectedType)
          : Center(
              child: Text(
                'Open the menu to select a type',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
            ),
      floatingActionButton: selectedType != null
          ? FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BrainEntityFormScreen(entityType: selectedType),
                ),
              ),
              backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              foregroundColor: Colors.white,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

/// Thin wrapper that supplies schema context to BrainEntityListScreen.
class _BrainEntityListPanel extends ConsumerWidget {
  final String entityType;
  const _BrainEntityListPanel({required this.entityType});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schemasAsync = ref.watch(brainSchemaDetailProvider);
    final schemaDetail = schemasAsync.valueOrNull?.where((s) => s.name == entityType).firstOrNull;

    return BrainEntityListScreen(
      entityType: entityType,
      schema: schemaDetail?.toSchema(),
    );
  }
}
