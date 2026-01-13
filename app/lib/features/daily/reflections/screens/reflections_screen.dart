import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../journal/models/reflection.dart';
import '../../journal/providers/journal_providers.dart';
import '../widgets/reflection_list_card.dart';

/// Provider for listing all available reflections
final reflectionListProvider = FutureProvider<List<({DateTime date, Reflection reflection})>>((ref) async {
  ref.watch(journalRefreshTriggerProvider);
  final service = await ref.watch(reflectionServiceFutureProvider.future);

  debugPrint('[ReflectionsScreen] Looking for reflections at: ${service.reflectionsPath}');

  final dates = await service.listReflectionDates();
  debugPrint('[ReflectionsScreen] Found ${dates.length} reflection dates: $dates');

  final reflections = <({DateTime date, Reflection reflection})>[];

  for (final date in dates) {
    final reflection = await service.loadReflection(date);
    if (reflection != null && reflection.hasContent) {
      reflections.add((date: date, reflection: reflection));
    }
  }

  debugPrint('[ReflectionsScreen] Loaded ${reflections.length} reflections');
  return reflections;
});

/// Screen showing all AI-generated reflections
class ReflectionsScreen extends ConsumerStatefulWidget {
  const ReflectionsScreen({super.key});

  @override
  ConsumerState<ReflectionsScreen> createState() => _ReflectionsScreenState();
}

class _ReflectionsScreenState extends ConsumerState<ReflectionsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reflectionsAsync = ref.watch(reflectionListProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(context, isDark),

            // Reflections list
            Expanded(
              child: reflectionsAsync.when(
                data: (reflections) => _buildReflectionsList(context, reflections),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stack) => _buildErrorState(context, error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        border: Border(
          bottom: BorderSide(
            color: isDark ? BrandColors.charcoal : BrandColors.stone,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reflections',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'AI-generated insights from your journal',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
          // Refresh button
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(reflectionListProvider),
          ),
        ],
      ),
    );
  }

  Widget _buildReflectionsList(
    BuildContext context,
    List<({DateTime date, Reflection reflection})> reflections,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (reflections.isEmpty) {
      return _buildEmptyState(context);
    }

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(reflectionListProvider);
      },
      color: BrandColors.forest,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: reflections.length,
        separatorBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Divider(
            height: 1,
            thickness: 0.5,
            color: isDark
                ? BrandColors.charcoal.withValues(alpha: 0.3)
                : BrandColors.stone.withValues(alpha: 0.3),
          ),
        ),
        itemBuilder: (context, index) {
          final item = reflections[index];
          return ReflectionListCard(
            reflection: item.reflection,
            onTap: () => _showReflectionDetail(context, item.reflection),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 64,
              color: isDark ? BrandColors.driftwood : BrandColors.stone,
            ),
            const SizedBox(height: 16),
            Text(
              'No reflections yet',
              style: theme.textTheme.titleLarge?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.charcoal,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Reflections are generated daily from your journal entries.\nKeep journaling and check back tomorrow!',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, Object error) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: BrandColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleLarge?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => ref.invalidate(reflectionListProvider),
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  void _showReflectionDetail(BuildContext context, Reflection reflection) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? BrandColors.charcoal : BrandColors.stone,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: BrandColors.turquoise.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        color: BrandColors.turquoise,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reflection',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: isDark ? BrandColors.softWhite : BrandColors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _formatDate(reflection.date),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: BrandColors.driftwood,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      color: BrandColors.driftwood,
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Content
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    reflection.content,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: isDark ? BrandColors.stone : BrandColors.charcoal,
                      height: 1.7,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
