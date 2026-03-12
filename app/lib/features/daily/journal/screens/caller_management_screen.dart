import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/journal_providers.dart';
import '../utils/agent_theme.dart';
import '../widgets/caller_detail_sheet.dart';
import 'agent_log_screen.dart';
import 'caller_edit_screen.dart';
import 'package:parachute/core/services/computer_service.dart'
    show CallerTemplate, DailyAgentInfo;

/// Full-screen Caller management — browse, enable/disable, and configure agents.
class CallerManagementScreen extends ConsumerWidget {
  const CallerManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final callersAsync = ref.watch(callersProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: const Text('Daily Agents'),
        backgroundColor: isDark
            ? BrandColors.nightSurface
            : BrandColors.softWhite,
        foregroundColor: isDark ? BrandColors.softWhite : BrandColors.ink,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      floatingActionButton: callersAsync.whenOrNull(
        data: (callers) => callers.isNotEmpty
            ? FloatingActionButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CallerEditScreen()),
                ),
                backgroundColor: isDark
                    ? BrandColors.nightForest
                    : BrandColors.forest,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add),
              )
            : null,
      ),
      body: callersAsync.when(
        loading: () => Center(
          child: CircularProgressIndicator(
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
        ),
        error: (error, _) => _ErrorView(
          message: error.toString(),
          onRetry: () => ref.invalidate(callersProvider),
        ),
        data: (callers) {
          if (callers.isEmpty) {
            return _EmptyCallersView(isDark: isDark);
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(callersProvider),
            color: BrandColors.forest,
            child: ListView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.md,
              ),
              itemCount: callers.length,
              itemBuilder: (context, index) =>
                  _CallerCard(caller: callers[index], isDark: isDark),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Caller Card — list item with toggle and tap-to-detail
// ─────────────────────────────────────────────────────────────────────────────

class _CallerCard extends ConsumerWidget {
  final DailyAgentInfo caller;
  final bool isDark;

  const _CallerCard({required this.caller, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final agentTheme = AgentTheme.forAgent(caller.name);

    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.md),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetail(context, ref),
          borderRadius: Radii.card,
          child: Container(
            padding: EdgeInsets.all(Spacing.lg),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              borderRadius: Radii.card,
              border: Border.all(
                color: isDark
                    ? agentTheme.color.withValues(alpha: 0.2)
                    : agentTheme.color.withValues(alpha: 0.15),
              ),
              boxShadow: isDark ? null : Elevation.cardShadow,
            ),
            child: Row(
              children: [
                // Agent icon
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: agentTheme.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(
                    agentTheme.icon,
                    size: 24,
                    color: agentTheme.color,
                  ),
                ),
                SizedBox(width: Spacing.md),
                // Name + description + schedule
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        caller.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      if (caller.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          caller.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                      SizedBox(height: Spacing.xs),
                      // Schedule badge
                      Row(
                        children: [
                          Icon(
                            caller.scheduleEnabled
                                ? Icons.schedule
                                : Icons.schedule_outlined,
                            size: 12,
                            color: caller.scheduleEnabled
                                ? agentTheme.color
                                : BrandColors.driftwood,
                          ),
                          SizedBox(width: Spacing.xs),
                          Text(
                            caller.scheduleEnabled
                                ? 'Runs at ${caller.scheduleTime}'
                                : 'Schedule off',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: caller.scheduleEnabled
                                  ? agentTheme.color
                                  : BrandColors.driftwood,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Schedule toggle
                Semantics(
                  label: 'Schedule ${caller.displayName}',
                  child: Switch.adaptive(
                    value: caller.scheduleEnabled,
                    onChanged: (enabled) =>
                        _toggleSchedule(context, ref, enabled),
                    activeColor: isDark
                        ? BrandColors.nightForest
                        : BrandColors.forest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleSchedule(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final api = ref.read(dailyApiServiceProvider);
    final success = await api.updateCaller(caller.name, {
      'schedule_enabled': enabled,
    });
    if (!context.mounted) return;
    if (success) {
      await api.reloadScheduler();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update ${caller.displayName}'),
          backgroundColor: BrandColors.error,
        ),
      );
    }
    // Always refresh to sync UI with server state
    ref.invalidate(callersProvider);
  }

  void _openDetail(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CallerDetailSheet(
        caller: caller,
        onViewHistory: () {
          Navigator.push(
            context, // parent screen's context — safe after sheet pops
            MaterialPageRoute(
              builder: (_) => AgentLogScreen(
                agentName: caller.name,
                displayName: caller.displayName,
              ),
            ),
          );
        },
        onEdit: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => CallerEditScreen(caller: caller)),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state — shows available templates
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyCallersView extends ConsumerWidget {
  final bool isDark;

  const _EmptyCallersView({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final templatesAsync = ref.watch(callerTemplatesProvider);

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 48,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'Get started with a Caller',
              style: theme.textTheme.titleMedium?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.sm),
            Text(
              'Callers are AI agents that read your journal and '
              'create reflections, insights, and more.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.xl),

            // Template cards
            templatesAsync.when(
              loading: () => Padding(
                padding: EdgeInsets.all(Spacing.lg),
                child: CircularProgressIndicator(
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
              error: (_, __) => _createBlankButton(context, isDark),
              data: (templates) {
                if (templates.isEmpty) {
                  return _createBlankButton(context, isDark);
                }
                return Column(
                  children: [
                    ...templates.map(
                      (t) => _TemplateCard(template: t, isDark: isDark),
                    ),
                    SizedBox(height: Spacing.md),
                    TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CallerEditScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Create from scratch'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _createBlankButton(BuildContext context, bool isDark) {
    return FilledButton.icon(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CallerEditScreen()),
      ),
      icon: const Icon(Icons.add),
      label: const Text('Create a Caller'),
      style: FilledButton.styleFrom(
        backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Template card — shown in empty state for one-tap creation
// ─────────────────────────────────────────────────────────────────────────────

class _TemplateCard extends StatelessWidget {
  final CallerTemplate template;
  final bool isDark;

  const _TemplateCard({required this.template, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agentTheme = AgentTheme.forAgent(template.name);

    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.md),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CallerEditScreen(template: template),
            ),
          ),
          borderRadius: Radii.card,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(Spacing.lg),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              borderRadius: Radii.card,
              border: Border.all(
                color: isDark
                    ? agentTheme.color.withValues(alpha: 0.3)
                    : agentTheme.color.withValues(alpha: 0.2),
              ),
              boxShadow: isDark ? null : Elevation.cardShadow,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: agentTheme.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(
                    agentTheme.icon,
                    size: 28,
                    color: agentTheme.color,
                  ),
                ),
                SizedBox(width: Spacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        template.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      if (template.description.isNotEmpty) ...[
                        SizedBox(height: Spacing.xs),
                        Text(
                          template.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: BrandColors.driftwood),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error state
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: BrandColors.error),
            SizedBox(height: Spacing.lg),
            Text(
              'Failed to load agents',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: Spacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: BrandColors.driftwood),
            ),
            SizedBox(height: Spacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
