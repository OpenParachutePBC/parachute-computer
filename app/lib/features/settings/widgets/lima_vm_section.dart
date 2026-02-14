import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/lima_vm_provider.dart';
import 'package:parachute/core/services/lima_vm_service.dart';

/// Settings section for managing the Lima VM (Parachute Computer)
///
/// Shows:
/// - VM status (not installed, stopped, running, etc.)
/// - Start/Stop/Create buttons
/// - Server status
/// - Open shell button
class LimaVMSection extends ConsumerStatefulWidget {
  const LimaVMSection({super.key});

  @override
  ConsumerState<LimaVMSection> createState() => _LimaVMSectionState();
}

class _LimaVMSectionState extends ConsumerState<LimaVMSection> {
  bool _isLoading = false;
  bool _autoStartEnabled = false;

  @override
  void initState() {
    super.initState();
    // Check status on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(limaVMServiceProvider).checkStatus();
      _checkAutoStart();
    });
  }

  Future<void> _checkAutoStart() async {
    final service = ref.read(limaVMServiceProvider);
    final enabled = await service.isAutoStartEnabled();
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Future<void> _toggleAutoStart(bool enable) async {
    final service = ref.read(limaVMServiceProvider);
    bool success;
    if (enable) {
      success = await service.enableAutoStart();
    } else {
      success = await service.disableAutoStart();
    }

    if (success && mounted) {
      setState(() => _autoStartEnabled = enable);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enable
              ? 'VM will start automatically on login'
              : 'Auto-start disabled'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Future<void> _startVM() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(limaVMServiceProvider);
      final success = await service.start();

      if (mounted) {
        if (success) {
          // Also start the server
          await service.startServer();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Parachute Computer started'),
              backgroundColor: BrandColors.success,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to start: ${service.lastError}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopVM() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(limaVMServiceProvider);
      final success = await service.stop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Parachute Computer stopped'
                : 'Failed to stop: ${service.lastError}'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openShell() async {
    final service = ref.read(limaVMServiceProvider);
    await service.openShell();
  }

  Future<void> _runClaudeLogin() async {
    final service = ref.read(limaVMServiceProvider);
    await service.runClaudeLogin();
  }

  Future<void> _startServer() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(limaVMServiceProvider);
      final success = await service.startServer();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Server started on port ${LimaVMService.serverPort}'
                : 'Failed to start server: ${service.lastError}'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only show on desktop
    if (!Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final limaAvailable = ref.watch(isLimaAvailableProvider);
    final vmStatusAsync = ref.watch(limaVMStatusProvider);
    // Service is read in build methods, watched here to trigger rebuilds
    ref.watch(limaVMServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.computer,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Parachute Computer',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const Spacer(),
            _buildStatusBadge(vmStatusAsync, isDark),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Isolated Linux VM where Claude can only access your vault.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Lima not installed
        limaAvailable.when(
          data: (installed) {
            if (!installed) {
              return _buildNotInstalledSection(isDark);
            }
            return vmStatusAsync.when(
              data: (status) => _buildVMControls(status, isDark),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error: $e'),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error checking Lima: $e'),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(AsyncValue<LimaVMStatus> statusAsync, bool isDark) {
    return statusAsync.when(
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
              if (status == LimaVMStatus.starting || status == LimaVMStatus.stopping)
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
      },
      loading: () => const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => const Icon(Icons.error, size: 14, color: BrandColors.error),
    );
  }

  Widget _buildNotInstalledSection(bool isDark) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: BrandColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: BrandColors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, size: 20, color: BrandColors.warning),
              SizedBox(width: Spacing.sm),
              Text(
                'Lima not installed',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Install Lima to run Parachute Computer:',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.sm),
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: SelectableText(
              'brew install lima',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVMControls(LimaVMStatus status, bool isDark) {
    final service = ref.read(limaVMServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server URL when running
        if (status == LimaVMStatus.running) ...[
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
                    'Server: ${service.serverUrl}',
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

        // Info box about isolation
        Container(
          padding: EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shield,
                    size: 16,
                    color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  ),
                  SizedBox(width: Spacing.xs),
                  Text(
                    'Isolation',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ],
              ),
              SizedBox(height: Spacing.xs),
              Text(
                'HOME is set to your vault, so Claude can only access:\n'
                '~/.claude/  ~/Daily/  ~/projects/  ~/CLAUDE.md',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Error message
        if (service.lastError != null && status == LimaVMStatus.error) ...[
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
          SizedBox(height: Spacing.lg),
        ],

        // Action buttons
        Row(
          children: [
            Expanded(
              child: _buildActionButton(status, isDark),
            ),
            if (status == LimaVMStatus.running) ...[
              SizedBox(width: Spacing.sm),
              IconButton(
                onPressed: _startServer,
                icon: const Icon(Icons.play_circle_outline),
                tooltip: 'Start Server',
                style: IconButton.styleFrom(
                  backgroundColor: isDark
                      ? BrandColors.nightSurfaceElevated
                      : BrandColors.stone,
                ),
              ),
              SizedBox(width: Spacing.xs),
              IconButton(
                onPressed: _openShell,
                icon: const Icon(Icons.terminal),
                tooltip: 'Open Terminal',
                style: IconButton.styleFrom(
                  backgroundColor: isDark
                      ? BrandColors.nightSurfaceElevated
                      : BrandColors.stone,
                ),
              ),
            ],
          ],
        ),

        // Auto-start toggle (when VM exists)
        if (status == LimaVMStatus.running || status == LimaVMStatus.stopped) ...[
          SizedBox(height: Spacing.lg),
          Container(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightSurface : BrandColors.stone)
                  .withValues(alpha: 0.5),
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
                      'Start VM on login',
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

        // Claude login section when running
        if (status == LimaVMStatus.running) ...[
          SizedBox(height: Spacing.lg),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.key,
                      size: 16,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.xs),
                    Text(
                      'Claude Authentication',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.xs),
                Text(
                  'Opens Terminal with auth URL. Copy the URL to your browser to authenticate.',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                SizedBox(height: Spacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _runClaudeLogin,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Run claude login'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton(LimaVMStatus status, bool isDark) {
    final isLoading = _isLoading ||
        status == LimaVMStatus.starting ||
        status == LimaVMStatus.stopping;

    if (status == LimaVMStatus.running) {
      return FilledButton.icon(
        onPressed: isLoading ? null : _stopVM,
        icon: isLoading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
                ),
              )
            : const Icon(Icons.stop, size: 18),
        label: Text(isLoading ? 'Stopping...' : 'Stop'),
        style: FilledButton.styleFrom(
          backgroundColor: BrandColors.error,
        ),
      );
    }

    final buttonLabel = switch (status) {
      LimaVMStatus.notCreated => 'Create & Start',
      LimaVMStatus.stopped => 'Start',
      LimaVMStatus.starting => 'Starting...',
      _ => 'Start',
    };

    return FilledButton.icon(
      onPressed: isLoading ? null : _startVM,
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
              ),
            )
          : const Icon(Icons.play_arrow, size: 18),
      label: Text(buttonLabel),
      style: FilledButton.styleFrom(
        backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
      ),
    );
  }
}
