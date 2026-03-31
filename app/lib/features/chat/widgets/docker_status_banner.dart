import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/models/supervisor_models.dart';
import 'package:parachute/core/providers/supervisor_providers.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:url_launcher/url_launcher.dart';

/// Banner shown when Docker is required but not running.
///
/// States:
/// 1. Docker not running → "Docker is needed. [Start Docker]"
/// 2. Docker starting → "Starting Docker… (elapsed)" with spinner
/// 3. No runtime detected → "No Docker runtime. [Get OrbStack →]"
class DockerStatusBanner extends ConsumerStatefulWidget {
  /// Whether the current session requires Docker (sandboxed trust level).
  final bool dockerRequired;

  /// Called when Docker becomes ready (so chat can auto-retry).
  final VoidCallback? onDockerReady;

  const DockerStatusBanner({
    super.key,
    required this.dockerRequired,
    this.onDockerReady,
  });

  @override
  ConsumerState<DockerStatusBanner> createState() => _DockerStatusBannerState();
}

class _DockerStatusBannerState extends ConsumerState<DockerStatusBanner> {
  bool _isStarting = false;
  DateTime? _startedAt;
  Timer? _elapsedTimer;

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleStartDocker() async {
    setState(() {
      _isStarting = true;
      _startedAt = DateTime.now();
    });

    // Tick every second to update elapsed time
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    final success =
        await ref.read(dockerStatusNotifierProvider.notifier).startDocker();

    _elapsedTimer?.cancel();

    if (mounted) {
      setState(() {
        _isStarting = false;
        _startedAt = null;
      });

      if (success) {
        widget.onDockerReady?.call();
      }
    }
  }

  String _formatElapsed() {
    if (_startedAt == null) return '';
    final elapsed = DateTime.now().difference(_startedAt!);
    return '${elapsed.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.dockerRequired) return const SizedBox.shrink();

    final dockerAsync = ref.watch(dockerStatusNotifierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return dockerAsync.when(
      data: (status) {
        if (status.daemonRunning) return const SizedBox.shrink();

        if (_isStarting) {
          return _buildStartingBanner(context, isDark, status);
        }

        if (!status.hasRuntime) {
          return _buildNoRuntimeBanner(context, isDark);
        }

        return _buildNotRunningBanner(context, isDark, status);
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildNotRunningBanner(
      BuildContext context, bool isDark, DockerStatus status) {
    final color = BrandColors.warning;
    final runtimeName = status.runtimeDisplay ?? 'Docker';

    return _BannerContainer(
      color: color,
      child: Row(
        children: [
          Icon(Icons.settings_suggest_rounded, color: color, size: 20),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              '$runtimeName is not running',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: TypographyTokens.bodySmall,
                color: color,
              ),
            ),
          ),
          _ActionButton(
            label: 'Start Docker',
            icon: Icons.play_arrow_rounded,
            onTap: _handleStartDocker,
            isDark: isDark,
            color: color,
          ),
        ],
      ),
    );
  }

  Widget _buildStartingBanner(
      BuildContext context, bool isDark, DockerStatus status) {
    final color = BrandColors.warning;
    final runtimeName = status.runtimeDisplay ?? 'Docker';

    return _BannerContainer(
      color: color,
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Starting $runtimeName\u2026 ${_formatElapsed()}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: TypographyTokens.bodySmall,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoRuntimeBanner(BuildContext context, bool isDark) {
    final color = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;

    return _BannerContainer(
      color: color,
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color, size: 20),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'No Docker runtime installed',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: TypographyTokens.bodySmall,
                color: color,
              ),
            ),
          ),
          _ActionButton(
            label: 'Get OrbStack',
            icon: Icons.open_in_new_rounded,
            onTap: () => launchUrl(Uri.parse('https://orbstack.dev')),
            isDark: isDark,
            color: color,
          ),
        ],
      ),
    );
  }
}

class _BannerContainer extends StatelessWidget {
  final Color color;
  final Widget child;

  const _BannerContainer({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
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
      child: SafeArea(bottom: false, child: child),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool isDark;
  final Color? color;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.isDark,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = color ??
        (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood);

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
              Icon(icon, size: 14, color: textColor),
              const SizedBox(width: Spacing.xs),
              Text(
                label,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
