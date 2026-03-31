import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/backend_health_provider.dart';
import 'package:parachute/core/services/backend_health_service.dart';

/// Banner that shows connection status when server is unreachable
class ConnectionStatusBanner extends ConsumerWidget {
  /// Called when user taps retry
  final VoidCallback? onRetry;

  /// Called when user taps settings
  final VoidCallback? onSettings;

  const ConnectionStatusBanner({
    super.key,
    this.onRetry,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthAsync = ref.watch(periodicServerHealthProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return healthAsync.when(
      data: (health) {
        // Don't show banner if connected or AI chat is disabled
        if (health == null || health.isHealthy) {
          return const SizedBox.shrink();
        }

        return _buildBanner(context, isDark, health, ref);
      },
      loading: () => _buildLoadingBanner(context, isDark),
      error: (e, _) => _buildErrorBanner(context, isDark, e.toString()),
    );
  }

  Widget _buildBanner(
    BuildContext context,
    bool isDark,
    ServerHealthStatus health,
    WidgetRef ref,
  ) {
    // Choose icon and color based on connection state
    IconData icon;
    Color color;

    switch (health.connectionState) {
      case ServerConnectionState.networkError:
        icon = Icons.wifi_off_rounded;
        color = BrandColors.warning;
        break;
      case ServerConnectionState.serverOffline:
        icon = Icons.cloud_off_rounded;
        color = BrandColors.error;
        break;
      case ServerConnectionState.timeout:
        icon = Icons.hourglass_empty_rounded;
        color = BrandColors.warning;
        break;
      default:
        icon = Icons.error_outline_rounded;
        color = BrandColors.error;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(
            color: color.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    health.message,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: TypographyTokens.bodySmall,
                      color: color,
                    ),
                  ),
                  if (health.helpText.isNotEmpty)
                    Text(
                      health.helpText,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                ],
              ),
            ),
            // Action buttons
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  onTap: onRetry ?? () {
                    ref.invalidate(periodicServerHealthProvider);
                  },
                  isDark: isDark,
                ),
                const SizedBox(width: Spacing.xs),
                _ActionButton(
                  label: 'Settings',
                  icon: Icons.settings_rounded,
                  onTap: onSettings,
                  isDark: isDark,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingBanner(BuildContext context, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: BrandColors.turquoise.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(
            color: BrandColors.turquoise.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              'Connecting to server...',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: BrandColors.turquoise,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, bool isDark, String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: BrandColors.error.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(
            color: BrandColors.error.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(Icons.error_outline, color: BrandColors.error, size: 20),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Connection check failed',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: BrandColors.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool isDark;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.badge,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                label,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
