import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/lima_vm_provider.dart';
import 'package:parachute/core/providers/bare_metal_provider.dart';
import 'package:parachute/core/services/lima_vm_service.dart';
import 'package:parachute/core/services/bare_metal_server_service.dart';

/// Unified settings section for Parachute Computer
///
/// Consolidates Lima VM and Bare Metal modes into a single section that:
/// - Shows current mode and status
/// - Provides start/stop controls
/// - Hides mode switching in an expandable "Advanced" section
class ParachuteComputerSection extends ConsumerStatefulWidget {
  const ParachuteComputerSection({super.key});

  @override
  ConsumerState<ParachuteComputerSection> createState() => _ParachuteComputerSectionState();
}

class _ParachuteComputerSectionState extends ConsumerState<ParachuteComputerSection> {
  bool _isLoading = false;
  bool _autoStartEnabled = false;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStatus();
      _checkAutoStart();
    });
  }

  Future<void> _checkStatus() async {
    final serverMode = await ref.read(serverModeProvider.future);
    if (serverMode == ServerMode.limaVM) {
      ref.read(limaVMServiceProvider).checkStatus();
    } else {
      ref.read(bareMetalServiceProvider).checkStatus();
    }
  }

  Future<void> _checkAutoStart() async {
    final serverMode = await ref.read(serverModeProvider.future);
    bool enabled;
    if (serverMode == ServerMode.limaVM) {
      enabled = await ref.read(limaVMServiceProvider).isAutoStartEnabled();
    } else {
      enabled = await ref.read(bareMetalServiceProvider).isAutoStartEnabled();
    }
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Future<void> _toggleAutoStart(bool enable) async {
    final serverMode = await ref.read(serverModeProvider.future);
    bool success;

    if (serverMode == ServerMode.limaVM) {
      final service = ref.read(limaVMServiceProvider);
      success = enable ? await service.enableAutoStart() : await service.disableAutoStart();
    } else {
      final service = ref.read(bareMetalServiceProvider);
      success = enable ? await service.enableAutoStart() : await service.disableAutoStart();
    }

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
      final serverMode = await ref.read(serverModeProvider.future);
      bool success;
      String? error;

      if (serverMode == ServerMode.limaVM) {
        final service = ref.read(limaVMServiceProvider);
        success = await service.start();
        if (success) {
          await service.startServer();
        }
        error = service.lastError;
      } else {
        final service = ref.read(bareMetalServiceProvider);
        success = await service.startServer();
        error = service.lastError;
      }

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
      final serverMode = await ref.read(serverModeProvider.future);
      bool success;
      String? error;

      if (serverMode == ServerMode.limaVM) {
        final service = ref.read(limaVMServiceProvider);
        success = await service.stop();
        error = service.lastError;
      } else {
        final service = ref.read(bareMetalServiceProvider);
        success = await service.stopServer();
        error = service.lastError;
      }

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
    final serverMode = await ref.read(serverModeProvider.future);
    if (serverMode == ServerMode.limaVM) {
      await ref.read(limaVMServiceProvider).runClaudeLogin();
    } else {
      await ref.read(bareMetalServiceProvider).runClaudeLogin();
    }
  }

  Future<void> _openShell() async {
    final serverMode = await ref.read(serverModeProvider.future);
    if (serverMode == ServerMode.limaVM) {
      await ref.read(limaVMServiceProvider).openShell();
    }
    // Bare metal doesn't have a shell concept
  }

  Future<void> _switchMode(ServerMode newMode) async {
    final currentMode = await ref.read(serverModeProvider.future);
    if (currentMode == newMode) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Switch to ${newMode == ServerMode.limaVM ? 'Lima VM' : 'Bare Metal'}?'),
        content: Text(
          newMode == ServerMode.limaVM
              ? 'This will use an isolated virtual machine. Claude can only access your vault.'
              : 'This will run directly on macOS for better performance.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Stop current server
    if (currentMode == ServerMode.limaVM) {
      final service = ref.read(limaVMServiceProvider);
      final status = await service.checkStatus();
      if (status == LimaVMStatus.running) {
        await service.stop();
      }
    } else {
      final service = ref.read(bareMetalServiceProvider);
      await service.stopServer();
    }

    // Switch mode
    await ref.read(serverModeProvider.notifier).setServerMode(newMode);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to ${newMode == ServerMode.limaVM ? 'Lima VM' : 'Bare Metal'} mode'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final serverModeAsync = ref.watch(serverModeProvider);

    return serverModeAsync.when(
      data: (serverMode) => _buildContent(isDark, serverMode),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
    );
  }

  Widget _buildContent(bool isDark, ServerMode serverMode) {
    final isLimaMode = serverMode == ServerMode.limaVM;

    // Watch the appropriate status provider
    final statusWidget = isLimaMode
        ? ref.watch(limaVMStatusProvider).when(
              data: (status) => _buildControls(isDark, serverMode, limaStatus: status),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error: $e'),
            )
        : ref.watch(bareMetalStatusProvider).when(
              data: (status) => _buildControls(isDark, serverMode, bareMetalStatus: status),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error: $e'),
            );

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parachute Computer',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: TypographyTokens.bodyLarge,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  Text(
                    isLimaMode ? 'Lima VM (Isolated)' : 'Bare Metal (Direct)',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            _buildStatusBadge(isDark, serverMode),
          ],
        ),
        SizedBox(height: Spacing.lg),

        // Main controls
        statusWidget,

        // Advanced section (collapsible)
        SizedBox(height: Spacing.lg),
        _buildAdvancedSection(isDark, serverMode),
      ],
    );
  }

  Widget _buildStatusBadge(bool isDark, ServerMode serverMode) {
    if (serverMode == ServerMode.limaVM) {
      return ref.watch(limaVMStatusProvider).when(
        data: (status) {
          final (icon, label, color) = switch (status) {
            LimaVMStatus.notInstalled => (Icons.warning, 'Not Installed', BrandColors.warning),
            LimaVMStatus.notCreated => (Icons.add_circle_outline, 'Not Created', BrandColors.driftwood),
            LimaVMStatus.stopped => (Icons.stop_circle, 'Stopped', BrandColors.driftwood),
            LimaVMStatus.starting => (Icons.play_circle, 'Starting', BrandColors.turquoise),
            LimaVMStatus.running => (Icons.check_circle, 'Running', BrandColors.success),
            LimaVMStatus.stopping => (Icons.stop_circle, 'Stopping', BrandColors.warning),
            LimaVMStatus.error => (Icons.error, 'Error', BrandColors.error),
          };
          return _StatusBadge(icon: icon, label: label, color: color, isLoading: status == LimaVMStatus.starting || status == LimaVMStatus.stopping);
        },
        loading: () => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => const Icon(Icons.error, size: 14, color: BrandColors.error),
      );
    } else {
      return ref.watch(bareMetalStatusProvider).when(
        data: (status) {
          final (icon, label, color) = switch (status) {
            BareMetalServerStatus.pythonNotInstalled => (Icons.warning, 'No Python', BrandColors.warning),
            BareMetalServerStatus.notInstalled => (Icons.warning, 'Not Installed', BrandColors.warning),
            BareMetalServerStatus.stopped => (Icons.stop_circle, 'Stopped', BrandColors.driftwood),
            BareMetalServerStatus.starting => (Icons.play_circle, 'Starting', BrandColors.turquoise),
            BareMetalServerStatus.running => (Icons.check_circle, 'Running', BrandColors.success),
            BareMetalServerStatus.stopping => (Icons.stop_circle, 'Stopping', BrandColors.warning),
            BareMetalServerStatus.error => (Icons.error, 'Error', BrandColors.error),
          };
          return _StatusBadge(icon: icon, label: label, color: color, isLoading: status == BareMetalServerStatus.starting || status == BareMetalServerStatus.stopping);
        },
        loading: () => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => const Icon(Icons.error, size: 14, color: BrandColors.error),
      );
    }
  }

  Widget _buildControls(bool isDark, ServerMode serverMode, {LimaVMStatus? limaStatus, BareMetalServerStatus? bareMetalStatus}) {
    final isRunning = (limaStatus == LimaVMStatus.running) || (bareMetalStatus == BareMetalServerStatus.running);
    final isStopped = (limaStatus == LimaVMStatus.stopped) || (limaStatus == LimaVMStatus.notCreated) ||
                      (bareMetalStatus == BareMetalServerStatus.stopped);
    final isTransitioning = (limaStatus == LimaVMStatus.starting) || (limaStatus == LimaVMStatus.stopping) ||
                            (bareMetalStatus == BareMetalServerStatus.starting) || (bareMetalStatus == BareMetalServerStatus.stopping);

    final serverUrl = serverMode == ServerMode.limaVM
        ? ref.read(limaVMServiceProvider).serverUrl
        : ref.read(bareMetalServiceProvider).serverUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                      label: Text(isTransitioning ? 'Starting...' : (isStopped ? 'Start' : 'Start')),
                      style: FilledButton.styleFrom(backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest),
                    ),
            ),
            // Shell button for Lima VM when running
            if (isRunning && serverMode == ServerMode.limaVM) ...[
              SizedBox(width: Spacing.sm),
              IconButton(
                onPressed: _openShell,
                icon: const Icon(Icons.terminal),
                tooltip: 'Open Terminal',
                style: IconButton.styleFrom(
                  backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
                ),
              ),
            ],
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

  Widget _buildAdvancedSection(bool isDark, ServerMode serverMode) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Row(
              children: [
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
                SizedBox(width: Spacing.xs),
                Text(
                  'Advanced',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    fontWeight: FontWeight.w500,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showAdvanced) ...[
          SizedBox(height: Spacing.sm),
          Text(
            'Server Mode',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.sm),
          _ModeOption(
            isDark: isDark,
            icon: Icons.security,
            title: 'Lima VM (Isolated)',
            description: 'Claude can only access your vault',
            isSelected: serverMode == ServerMode.limaVM,
            onTap: () => _switchMode(ServerMode.limaVM),
          ),
          SizedBox(height: Spacing.sm),
          _ModeOption(
            isDark: isDark,
            icon: Icons.speed,
            title: 'Bare Metal (Direct)',
            description: 'Best performance, native ML',
            isSelected: serverMode == ServerMode.bareMetal,
            onTap: () => _switchMode(ServerMode.bareMetal),
          ),
        ],
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isLoading;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
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

class _ModeOption extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.isDark,
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;

    return InkWell(
      onTap: isSelected ? null : onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        padding: EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withValues(alpha: 0.1)
              : (isDark ? BrandColors.nightSurface : BrandColors.stone).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: isSelected ? accentColor : Colors.transparent,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? accentColor : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, size: 20, color: accentColor),
          ],
        ),
      ),
    );
  }
}
