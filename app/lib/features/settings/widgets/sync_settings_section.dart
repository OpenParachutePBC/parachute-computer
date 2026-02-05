import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show syncModeProvider, SyncMode;
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/services/sync_service.dart';

/// Daily sync settings and status section
class SyncSettingsSection extends ConsumerWidget {
  const SyncSettingsSection({super.key});

  String _formatLastSync(DateTime time, SyncResult? result) {
    final now = DateTime.now();
    final diff = now.difference(time);

    String timeAgo;
    if (diff.inMinutes < 1) {
      timeAgo = 'just now';
    } else if (diff.inMinutes < 60) {
      timeAgo = '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      timeAgo = '${diff.inHours}h ago';
    } else {
      timeAgo = '${diff.inDays}d ago';
    }

    if (result != null && result.success) {
      return 'Last sync: $timeAgo (↑${result.pushed} ↓${result.pulled})';
    }
    return 'Last sync: $timeAgo';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final syncState = ref.watch(syncProvider);
    final syncNotifier = ref.read(syncProvider.notifier);
    final syncModeAsync = ref.watch(syncModeProvider);
    final syncModeNotifier = ref.read(syncModeProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.sync,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Daily Sync',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            // Conflict badge
            if (syncState.hasConflicts) ...[
              SizedBox(width: Spacing.xs),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.xs,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: BrandColors.warning,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  '${syncState.unresolvedConflicts.length}',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    fontWeight: FontWeight.bold,
                    color: BrandColors.softWhite,
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (syncState.isSyncing)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  ),
                ),
              )
            else if (syncState.hasConflicts)
              Icon(Icons.warning_amber_rounded, color: BrandColors.warning, size: 20)
            else if (syncState.status == SyncStatus.success)
              Icon(Icons.check_circle, color: BrandColors.success, size: 20)
            else if (syncState.hasError)
              Icon(Icons.error, color: BrandColors.error, size: 20),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Sync your Daily journals with your Parachute Base server.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Sync Mode Toggle
        syncModeAsync.when(
          data: (syncMode) => Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Include media files',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        fontWeight: FontWeight.w500,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                    Switch(
                      value: syncMode == SyncMode.full,
                      onChanged: (value) {
                        syncModeNotifier.setSyncMode(
                          value ? SyncMode.full : SyncMode.textOnly,
                        );
                      },
                      activeColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                    ),
                  ],
                ),
                SizedBox(height: Spacing.xs),
                Text(
                  syncMode == SyncMode.full
                      ? 'Syncing all files including audio and images (uses more bandwidth)'
                      : 'Syncing text files only (faster, less bandwidth)',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        SizedBox(height: Spacing.md),

        // Last sync info
        if (syncState.lastSyncTime != null) ...[
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.history,
                  size: 16,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    _formatLastSync(syncState.lastSyncTime!, syncState.lastResult),
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),
        ],

        // Error message
        if (syncState.hasError && syncState.errorMessage != null) ...[
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: BrandColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: BrandColors.error),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    syncState.errorMessage!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: BrandColors.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),
        ],

        // Conflicts info
        if (syncState.hasConflicts) ...[
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: BrandColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: BrandColors.warning.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: BrandColors.warning),
                    SizedBox(width: Spacing.xs),
                    Text(
                      '${syncState.unresolvedConflicts.length} conflict${syncState.unresolvedConflicts.length == 1 ? '' : 's'} detected',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        fontWeight: FontWeight.w600,
                        color: BrandColors.warning,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.xs),
                Text(
                  'Conflicting edits were saved with .sync-conflict suffix. Check your Daily folder for conflict files.',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                SizedBox(height: Spacing.sm),
                // Show conflict file list (truncated)
                ...syncState.unresolvedConflicts.take(3).map((conflict) => Padding(
                  padding: EdgeInsets.only(top: Spacing.xs),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 12,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      SizedBox(width: Spacing.xs),
                      Expanded(
                        child: Text(
                          conflict.split('/').last,
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )),
                if (syncState.unresolvedConflicts.length > 3)
                  Padding(
                    padding: EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      '+${syncState.unresolvedConflicts.length - 3} more',
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        fontStyle: FontStyle.italic,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),
        ],

        // Sync button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: syncState.isSyncing
                ? null
                : () async {
                    final result = await syncNotifier.sync(pattern: '*');
                    if (context.mounted && result.success) {
                      // Build message with optional conflict info
                      final mergedStr = result.merged > 0 ? ', ${result.merged} merged' : '';
                      final conflictStr = result.conflicts.isNotEmpty
                          ? ' (${result.conflicts.length} conflict${result.conflicts.length == 1 ? '' : 's'})'
                          : '';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Synced: ${result.pushed} pushed, ${result.pulled} pulled$mergedStr$conflictStr',
                          ),
                          backgroundColor: result.conflicts.isNotEmpty
                              ? BrandColors.warning
                              : BrandColors.success,
                        ),
                      );
                    }
                  },
            icon: syncState.isSyncing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
                    ),
                  )
                : const Icon(Icons.sync, size: 18),
            label: Text(syncState.isSyncing ? 'Syncing...' : 'Sync Now'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
        ),
      ],
    );
  }
}
