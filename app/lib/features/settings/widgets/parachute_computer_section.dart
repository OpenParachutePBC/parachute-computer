import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/bare_metal_provider.dart';
import 'package:parachute/core/services/bare_metal_server_service.dart';

/// Settings section for Parachute Computer
///
/// Shows server status and provides start/stop controls for the bare metal server.
class ParachuteComputerSection extends ConsumerStatefulWidget {
  const ParachuteComputerSection({super.key});

  @override
  ConsumerState<ParachuteComputerSection> createState() => _ParachuteComputerSectionState();
}

class _ParachuteComputerSectionState extends ConsumerState<ParachuteComputerSection> {
  bool _isLoading = false;
  bool _autoStartEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStatus();
      _checkAutoStart();
    });
  }

  Future<void> _checkStatus() async {
    ref.read(bareMetalServiceProvider).checkStatus();
  }

  Future<void> _checkAutoStart() async {
    final enabled = await ref.read(bareMetalServiceProvider).isAutoStartEnabled();
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Future<void> _toggleAutoStart(bool enable) async {
    final service = ref.read(bareMetalServiceProvider);
    final success = enable ? await service.enableAutoStart() : await service.disableAutoStart();

    if (success && mounted) {
      setState(() => _autoStartEnabled = enable);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enable ? 'Auto-start enabled' : 'Auto-start disabled'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Future<void> _start() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(bareMetalServiceProvider);
      final success = await service.startServer();
      final error = service.lastError;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'Server started' : 'Failed to start: $error'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(bareMetalServiceProvider);
      final success = await service.stopServer();
      final error = service.lastError;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'Server stopped' : 'Failed to stop: $error'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _runClaudeLogin() async {
    await ref.read(bareMetalServiceProvider).runClaudeLogin();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ref.watch(bareMetalStatusProvider).when(
      data: (status) => _buildContent(isDark, status),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
    );
  }

  Widget _buildContent(bool isDark, BareMetalServerStatus status) {
    final isRunning = status == BareMetalServerStatus.running;
    final isStopped = status == BareMetalServerStatus.stopped;
    final isTransitioning = status == BareMetalServerStatus.starting || status == BareMetalServerStatus.stopping;
    final serverUrl = ref.read(bareMetalServiceProvider).serverUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with status
        Row(
          children: [
            Icon(
              Icons.computer,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Parachute Computer',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
            _buildStatusBadge(status),
          ],
        ),
        SizedBox(height: Spacing.lg),

        // Server URL when running
        if (isRunning) ...[
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.success.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, size: 16, color: BrandColors.success),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: SelectableText(
                    'Server: $serverUrl',
                    style: TextStyle(
                      fontFamily: 'monospace',
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

        // Start/Stop button
        Row(
          children: [
            Expanded(
              child: isRunning
                  ? FilledButton.icon(
                      onPressed: (_isLoading || isTransitioning) ? null : _stop,
                      icon: (_isLoading || isTransitioning)
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.stop, size: 18),
                      label: Text(isTransitioning ? 'Stopping...' : 'Stop'),
                      style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
                    )
                  : FilledButton.icon(
                      onPressed: (_isLoading || isTransitioning) ? null : _start,
                      icon: (_isLoading || isTransitioning)
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(isTransitioning ? 'Starting...' : 'Start'),
                      style: FilledButton.styleFrom(backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest),
                    ),
            ),
          ],
        ),

        // Auto-start toggle
        if (isRunning || isStopped) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightSurface : BrandColors.stone).withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.power_settings_new,
                      size: 18,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                    SizedBox(width: Spacing.sm),
                    Text(
                      'Start on login',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: _autoStartEnabled,
                  onChanged: _toggleAutoStart,
                  activeColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                ),
              ],
            ),
          ),
        ],

        // Claude login when running
        if (isRunning) ...[
          SizedBox(height: Spacing.md),
          OutlinedButton.icon(
            onPressed: _runClaudeLogin,
            icon: const Icon(Icons.key, size: 18),
            label: const Text('Claude Login'),
          ),
        ],
      ],
    );
  }

  Widget _buildStatusBadge(BareMetalServerStatus status) {
    final (icon, label, color) = switch (status) {
      BareMetalServerStatus.pythonNotInstalled => (Icons.warning, 'No Python', BrandColors.warning),
      BareMetalServerStatus.notInstalled => (Icons.warning, 'Not Installed', BrandColors.warning),
      BareMetalServerStatus.stopped => (Icons.stop_circle, 'Stopped', BrandColors.driftwood),
      BareMetalServerStatus.starting => (Icons.play_circle, 'Starting', BrandColors.turquoise),
      BareMetalServerStatus.running => (Icons.check_circle, 'Running', BrandColors.success),
      BareMetalServerStatus.stopping => (Icons.stop_circle, 'Stopping', BrandColors.warning),
      BareMetalServerStatus.error => (Icons.error, 'Error', BrandColors.error),
    };
    final isLoading = status == BareMetalServerStatus.starting || status == BareMetalServerStatus.stopping;

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
          if (isLoading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            )
          else
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
