import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/base_server_provider.dart';
import 'package:parachute/core/services/base_server_service.dart';
import '../providers/journal_providers.dart';

/// Provider for agent trigger state (per agent)
final agentTriggerStateProvider = StateProvider.family<AsyncValue<AgentRunResult?>, String>(
  (ref, agentName) => const AsyncValue.data(null),
);

/// Card that allows triggering any daily agent.
///
/// Shows different states:
/// - Server not connected: shows connection status
/// - Ready: shows button to generate
/// - Generating: shows progress
/// - Error: shows error message
class AgentTriggerCard extends ConsumerStatefulWidget {
  final DailyAgentInfo agent;
  final DateTime date;
  final VoidCallback? onOutputGenerated;

  const AgentTriggerCard({
    super.key,
    required this.agent,
    required this.date,
    this.onOutputGenerated,
  });

  @override
  ConsumerState<AgentTriggerCard> createState() => _AgentTriggerCardState();
}

class _AgentTriggerCardState extends ConsumerState<AgentTriggerCard> {
  bool _isTriggering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Watch server connectivity
    final serverConnected = ref.watch(serverConnectedProvider);
    final triggerState = ref.watch(agentTriggerStateProvider(widget.agent.name));

    // Choose icon and color based on agent type
    final (icon, color) = _getAgentIconAndColor(widget.agent.name);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? BrandColors.charcoal.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
      ),
      child: serverConnected.when(
        data: (connected) {
          if (!connected) {
            return _buildDisconnectedState(context, isDark, icon, color);
          }
          if (_isTriggering) {
            return _buildLoadingState(context, isDark, icon, color);
          }
          return triggerState.when(
            data: (result) {
              if (result == null) {
                return _buildReadyState(context, isDark, icon, color);
              }
              if (result.success) {
                return _buildSuccessState(context, result, isDark, icon, color);
              }
              return _buildErrorState(context, result, isDark, icon, color);
            },
            loading: () => _buildLoadingState(context, isDark, icon, color),
            error: (e, _) => _buildErrorState(
              context,
              AgentRunResult(success: false, status: 'error', error: e.toString()),
              isDark,
              icon,
              color,
            ),
          );
        },
        loading: () => _buildCheckingState(context, isDark),
        error: (e, _) => _buildDisconnectedState(context, isDark, icon, color),
      ),
    );
  }

  Widget _buildCheckingState(BuildContext context, bool isDark) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'Checking server connection...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedState(BuildContext context, bool isDark, IconData icon, Color color) {
    return Row(
      children: [
        Icon(
          Icons.cloud_off,
          size: 20,
          color: BrandColors.driftwood,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Base server not connected',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                ),
              ),
              Text(
                'Start the Parachute Base server to run ${widget.agent.displayName}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReadyState(BuildContext context, bool isDark, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Run ${widget.agent.displayName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          widget.agent.description,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _triggerAgent,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Generate'),
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState(BuildContext context, bool isDark, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Running ${widget.agent.displayName}...',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'This may take a minute or two',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          backgroundColor: isDark
              ? BrandColors.charcoal
              : BrandColors.stone.withValues(alpha: 0.3),
          color: color,
        ),
      ],
    );
  }

  Widget _buildSuccessState(
    BuildContext context,
    AgentRunResult result,
    bool isDark,
    IconData icon,
    Color color,
  ) {
    // Notify parent that output was generated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onOutputGenerated?.call();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.check_circle,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                result.status == 'skipped' ? 'Already generated' : 'Output created!',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        if (result.outputPath != null) ...[
          const SizedBox(height: 8),
          Text(
            result.outputPath!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: BrandColors.driftwood,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: _reset,
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildErrorState(
    BuildContext context,
    AgentRunResult result,
    bool isDark,
    IconData icon,
    Color color,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.error_outline,
              size: 20,
              color: BrandColors.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Failed to run ${widget.agent.displayName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          result.error ?? 'Unknown error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: _reset,
              child: const Text('Dismiss'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _triggerAgent,
              style: FilledButton.styleFrom(
                backgroundColor: color,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ],
    );
  }

  void _triggerAgent() async {
    setState(() => _isTriggering = true);

    try {
      final server = BaseServerService();
      final dateStr = _formatDate(widget.date);
      final result = await server.triggerDailyAgent(widget.agent.name, date: dateStr);

      ref.read(agentTriggerStateProvider(widget.agent.name).notifier).state =
          AsyncValue.data(result);

      // Trigger refresh to pick up new output
      if (result.success) {
        ref.read(journalRefreshTriggerProvider.notifier).state++;
      }
    } catch (e) {
      ref.read(agentTriggerStateProvider(widget.agent.name).notifier).state =
          AsyncValue.error(e, StackTrace.current);
    } finally {
      if (mounted) {
        setState(() => _isTriggering = false);
      }
    }
  }

  void _reset() {
    ref.read(agentTriggerStateProvider(widget.agent.name).notifier).state =
        const AsyncValue.data(null);
    ref.invalidate(selectedReflectionProvider);
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  (IconData, Color) _getAgentIconAndColor(String agentName) {
    switch (agentName) {
      case 'reflection':
        return (Icons.wb_twilight, BrandColors.forest);
      case 'content-scout':
        return (Icons.lightbulb_outline, BrandColors.turquoise);
      default:
        return (Icons.smart_toy_outlined, BrandColors.driftwood);
    }
  }
}
