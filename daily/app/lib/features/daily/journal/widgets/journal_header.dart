import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/services/sync_service.dart' show SyncStatus;
import '../models/journal_day.dart';
import '../providers/journal_providers.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';

/// Journal screen header with date navigation and sync controls
class JournalHeader extends ConsumerWidget {
  final DateTime selectedDate;
  final bool isToday;
  final AsyncValue<JournalDay> journalAsync;
  final VoidCallback onRefresh;

  const JournalHeader({
    super.key,
    required this.selectedDate,
    required this.isToday,
    required this.journalAsync,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Format the display date
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final displayDate = '${months[selectedDate.month - 1]} ${selectedDate.day}, ${selectedDate.year}';

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
          // Date navigation (left arrow)
          IconButton(
            icon: Icon(
              Icons.chevron_left,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            onPressed: () {
              ref.read(selectedJournalDateProvider.notifier).state =
                  selectedDate.subtract(const Duration(days: 1));
            },
          ),

          Expanded(
            child: GestureDetector(
              onTap: () => _showDatePicker(context, ref),
              child: Column(
                children: [
                  Text(
                    'Parachute Daily',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    displayDate,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),

          // Date navigation (right arrow) - disabled if today
          IconButton(
            icon: Icon(
              Icons.chevron_right,
              color: isToday
                  ? (isDark ? BrandColors.charcoal : BrandColors.stone)
                  : (isDark ? BrandColors.driftwood : BrandColors.charcoal),
            ),
            onPressed: isToday
                ? null
                : () {
                    ref.read(selectedJournalDateProvider.notifier).state =
                        selectedDate.add(const Duration(days: 1));
                  },
          ),

          // Sync/Refresh button with status indicator
          _SyncButton(isDark: isDark, onRefresh: onRefresh),

          // Settings button
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDatePicker(BuildContext context, WidgetRef ref) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      ref.read(selectedJournalDateProvider.notifier).state = picked;
    }
  }
}

/// Sync button with status indicator
class _SyncButton extends ConsumerWidget {
  final bool isDark;
  final VoidCallback onRefresh;

  const _SyncButton({
    required this.isDark,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final syncAvailable = ref.watch(syncAvailableProvider);

    // Don't show if sync not configured
    if (!syncAvailable) {
      return const SizedBox.shrink();
    }

    final color = isDark ? BrandColors.driftwood : BrandColors.charcoal;
    final successColor = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;

    Widget icon;
    String tooltip;

    if (syncState.isSyncing) {
      // Syncing - show progress indicator
      final progress = syncState.progress;
      if (progress != null && progress.total > 0) {
        // Show determinate progress
        icon = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            value: progress.percentage,
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            backgroundColor: color.withValues(alpha: 0.2),
          ),
        );
        tooltip = syncState.progressText ?? 'Syncing...';
      } else {
        // Show indeterminate progress
        icon = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        );
        tooltip = 'Syncing...';
      }
    } else if (syncState.status == SyncStatus.success) {
      // Just completed - show checkmark
      icon = Icon(Icons.cloud_done, color: successColor);
      tooltip = 'Synced';
    } else if (syncState.hasError) {
      // Error - show warning
      icon = Icon(Icons.cloud_off, color: BrandColors.error);
      tooltip = 'Sync error: ${syncState.errorMessage ?? "Unknown"}';
    } else {
      // Idle - show sync icon
      icon = Icon(Icons.sync, color: color);
      tooltip = syncState.lastSyncTime != null
          ? 'Last sync: ${_formatSyncTime(syncState.lastSyncTime!)}'
          : 'Tap to sync';
    }

    return IconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: syncState.isSyncing ? null : onRefresh,
    );
  }

  String _formatSyncTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) {
      return 'just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }
}
