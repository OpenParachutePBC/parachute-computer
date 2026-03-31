import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/core/services/bundled_server_service.dart';

/// Settings section for managing the bundled server (desktop only)
///
/// Shows:
/// - Server status (running, stopped, error)
/// - Start/stop/restart controls
/// - Server URL when running
/// - Error messages if any
class BundledServerSection extends ConsumerWidget {
  const BundledServerSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverStatus = ref.watch(serverStatusProvider);
    final isBundled = ref.watch(isBundledAppProvider);
    final service = ref.watch(bundledServerServiceProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Don't show this section if not a bundled app
    if (!isBundled && serverStatus == ServerStatus.notBundled) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.dns_outlined,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Bundled Server',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const Spacer(),
            _StatusBadge(status: serverStatus, isDark: isDark),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'The Parachute server is bundled with this app for a fully integrated experience.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),

        // Server URL when running
        if (serverStatus == ServerStatus.running) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.success.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 20, color: BrandColors.success),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Server running',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                      Text(
                        service.serverUrl,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],

        // Error message
        if (serverStatus == ServerStatus.error && service.lastError != null) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 20, color: BrandColors.error),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    service.lastError!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: BrandColors.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Starting indicator
        if (serverStatus == ServerStatus.starting) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                    ),
                  ),
                ),
                SizedBox(width: Spacing.sm),
                Text(
                  'Starting server...',
                  style: TextStyle(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ],
            ),
          ),
        ],

        SizedBox(height: Spacing.lg),

        // Control buttons
        Row(
          children: [
            if (serverStatus == ServerStatus.running || serverStatus == ServerStatus.error) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await ref.read(serverControlProvider.notifier).restart();
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Restart'),
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await ref.read(serverControlProvider.notifier).stop();
                  },
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Stop'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrandColors.error,
                  ),
                ),
              ),
            ] else if (serverStatus == ServerStatus.stopped) ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await ref.read(serverControlProvider.notifier).start();
                  },
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Start Server'),
                  style: FilledButton.styleFrom(
                    backgroundColor: BrandColors.success,
                  ),
                ),
              ),
            ] else if (serverStatus == ServerStatus.starting) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.hourglass_empty, size: 18),
                  label: const Text('Starting...'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Status badge showing server state
class _StatusBadge extends StatelessWidget {
  final ServerStatus status;
  final bool isDark;

  const _StatusBadge({required this.status, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (status) {
      ServerStatus.running => (Icons.check_circle, 'Running', BrandColors.success),
      ServerStatus.stopped => (Icons.circle_outlined, 'Stopped', BrandColors.driftwood),
      ServerStatus.starting => (Icons.sync, 'Starting', BrandColors.turquoise),
      ServerStatus.error => (Icons.error_outline, 'Error', BrandColors.error),
      ServerStatus.notBundled => (Icons.cloud_off, 'External', BrandColors.driftwood),
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          SizedBox(width: Spacing.xs),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
