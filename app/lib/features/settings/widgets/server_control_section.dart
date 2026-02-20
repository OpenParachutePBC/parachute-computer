import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/supervisor_providers.dart';

/// Server control section - status, restart, update via supervisor
class ServerControlSection extends ConsumerWidget {
  const ServerControlSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusAsync = ref.watch(supervisorStatusNotifierProvider);
    final serverControl = ref.watch(serverControlProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Server',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.xs),
        Text(
          'Manage the Parachute server',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
          ),
        ),
        SizedBox(height: Spacing.md),

        // Server status
        statusAsync.when(
          data: (status) => _buildStatusCard(context, status, isDark),
          loading: () => _buildLoadingCard(context, isDark),
          error: (_, __) => _buildErrorCard(context, isDark),
        ),

        SizedBox(height: Spacing.md),

        // Control buttons
        statusAsync.when(
          data: (status) => _buildControlButtons(
            context,
            ref,
            status,
            serverControl.isLoading,
            isDark,
          ),
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildStatusCard(BuildContext context, dynamic status, bool isDark) {
    final isHealthy = status.mainServerHealthy;
    final serverStatus = status.mainServerStatus; // "running" | "stopped"

    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.softWhite.withValues(alpha: 0.5),
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          // Status indicator
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHealthy
                  ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                  : (isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.stone),
            ),
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  serverStatus == 'running' ? 'Running' : 'Stopped',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.ink,
                  ),
                ),
                if (isHealthy && status.mainServerPort != null)
                  Text(
                    'Port ${status.mainServerPort}',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.stone,
                    ),
                  ),
                if (isHealthy && status.mainServerUptimeSeconds != null)
                  Text(
                    _formatUptime(status.mainServerUptimeSeconds!),
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.stone,
                    ),
                  ),
              ],
            ),
          ),
          // Version badge
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Supervisor v${status.supervisorVersion}',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.stone,
                ),
              ),
              if (status.mainServerVersion != null)
                Text(
                  'Server v${status.mainServerVersion}',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.stone,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingCard(BuildContext context, bool isDark) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.softWhite.withValues(alpha: 0.5),
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
          SizedBox(width: Spacing.sm),
          Text(
            'Checking status...',
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, bool isDark) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.softWhite.withValues(alpha: 0.5),
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_outlined,
            size: 20,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Supervisor not responding',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.stone,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButtons(
    BuildContext context,
    WidgetRef ref,
    dynamic status,
    bool isLoading,
    bool isDark,
  ) {
    final isRunning = status.mainServerStatus == 'running';

    return Row(
      children: [
        // Restart button
        Expanded(
          child: ElevatedButton.icon(
            onPressed: isLoading
                ? null
                : () async {
                    await ref.read(serverControlProvider.notifier).restart();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Server restarting...'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
            icon: isLoading
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.stone,
                    ),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: const Text('Restart'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              foregroundColor:
                  isDark ? BrandColors.nightText : BrandColors.ink,
              padding: EdgeInsets.symmetric(
                vertical: Spacing.sm,
                horizontal: Spacing.md,
              ),
            ),
          ),
        ),
        SizedBox(width: Spacing.sm),

        // Stop/Start button
        Expanded(
          child: ElevatedButton.icon(
            onPressed: isLoading
                ? null
                : () async {
                    if (isRunning) {
                      await ref.read(serverControlProvider.notifier).stop();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Server stopped'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    } else {
                      await ref.read(serverControlProvider.notifier).start();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Server starting...'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
            icon: Icon(
              isRunning ? Icons.stop : Icons.play_arrow,
              size: 18,
            ),
            label: Text(isRunning ? 'Stop' : 'Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              foregroundColor:
                  isDark ? BrandColors.nightText : BrandColors.ink,
              padding: EdgeInsets.symmetric(
                vertical: Spacing.sm,
                horizontal: Spacing.md,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatUptime(int seconds) {
    if (seconds < 60) return 'Up ${seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return 'Up ${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return 'Up ${hours}h';
    final days = hours ~/ 24;
    return 'Up ${days}d';
  }
}
