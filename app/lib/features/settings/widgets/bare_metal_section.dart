import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/bare_metal_provider.dart';
import 'package:parachute/core/services/bare_metal_server_service.dart';

/// Settings section for managing the bare metal server (Parachute Computer - Direct)
///
/// Shows:
/// - Server status (stopped, running, etc.)
/// - Start/Stop buttons
/// - Server health status
/// - Auto-start toggle
/// - Claude authentication
class BareMetalSection extends ConsumerStatefulWidget {
  const BareMetalSection({super.key});

  @override
  ConsumerState<BareMetalSection> createState() => _BareMetalSectionState();
}

class _BareMetalSectionState extends ConsumerState<BareMetalSection> {
  bool _isLoading = false;
  bool _autoStartEnabled = false;

  @override
  void initState() {
    super.initState();
    // Check status on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(bareMetalServiceProvider).checkStatus();
      _checkAutoStart();
    });
  }

  Future<void> _checkAutoStart() async {
    final service = ref.read(bareMetalServiceProvider);
    final enabled = await service.isAutoStartEnabled();
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Future<void> _toggleAutoStart(bool enable) async {
    final service = ref.read(bareMetalServiceProvider);
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
              ? 'Server will start automatically on login'
              : 'Auto-start disabled'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Future<void> _startServer() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(bareMetalServiceProvider);
      final success = await service.startServer();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Server started on port ${BareMetalServerService.serverPort}'
                : 'Failed to start: ${service.lastError}'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopServer() async {
    setState(() => _isLoading = true);
    try {
      final service = ref.read(bareMetalServiceProvider);
      final success = await service.stopServer();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Server stopped'
                : 'Failed to stop: ${service.lastError}'),
            backgroundColor: success ? BrandColors.success : BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _runClaudeLogin() async {
    final service = ref.read(bareMetalServiceProvider);
    await service.runClaudeLogin();
  }

  @override
  Widget build(BuildContext context) {
    // Only show on desktop
    if (!Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final serverStatusAsync = ref.watch(bareMetalStatusProvider);
    final pythonInstalled = ref.watch(isPythonInstalledProvider);
    // Service is read in build methods, watched here to trigger rebuilds
    ref.watch(bareMetalServiceProvider);

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
            _buildStatusBadge(serverStatusAsync, isDark),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Server running directly on macOS for best performance.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Python not installed
        pythonInstalled.when(
          data: (installed) {
            if (!installed) {
              return _buildPythonNotInstalledSection(isDark);
            }
            return serverStatusAsync.when(
              data: (status) => _buildServerControls(status, isDark),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Error: $e'),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error checking Python: $e'),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(AsyncValue<BareMetalServerStatus> statusAsync, bool isDark) {
    return statusAsync.when(
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
              if (status == BareMetalServerStatus.starting || status == BareMetalServerStatus.stopping)
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

  Widget _buildPythonNotInstalledSection(bool isDark) {
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
                'Python not installed',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Python 3.10+ is required. Install via Homebrew:',
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
              'brew install python@3.12',
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

  Widget _buildServerControls(BareMetalServerStatus status, bool isDark) {
    final service = ref.read(bareMetalServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server URL when running
        if (status == BareMetalServerStatus.running) ...[
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

        // Performance info box
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
                    Icons.speed,
                    size: 16,
                    color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  ),
                  SizedBox(width: Spacing.xs),
                  Text(
                    'Direct Installation',
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
                'Full native performance with access to MLX, Metal, and native builds. Best for dedicated Parachute machines.',
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
        if (service.lastError != null && status == BareMetalServerStatus.error) ...[
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
          ],
        ),

        // Auto-start toggle (when server exists)
        if (status == BareMetalServerStatus.running || status == BareMetalServerStatus.stopped) ...[
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
                      'Start server on login',
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
        if (status == BareMetalServerStatus.running) ...[
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
                  'Opens Terminal to authenticate with your Anthropic account.',
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

  Widget _buildActionButton(BareMetalServerStatus status, bool isDark) {
    final isLoading = _isLoading ||
        status == BareMetalServerStatus.starting ||
        status == BareMetalServerStatus.stopping;

    if (status == BareMetalServerStatus.running) {
      return FilledButton.icon(
        onPressed: isLoading ? null : _stopServer,
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
      BareMetalServerStatus.pythonNotInstalled => 'Install Python',
      BareMetalServerStatus.notInstalled => 'Set Up Server',
      BareMetalServerStatus.stopped => 'Start',
      BareMetalServerStatus.starting => 'Starting...',
      _ => 'Start',
    };

    return FilledButton.icon(
      onPressed: isLoading ? null : _startServer,
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
