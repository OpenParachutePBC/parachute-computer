import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/agent_output.dart';
import '../providers/journal_providers.dart';
import 'agent_output_header.dart';

/// Section showing agent outputs (reflections, content ideas, etc.)
class JournalAgentOutputsSection extends ConsumerWidget {
  final List<AgentOutput> outputs;
  final DateTime date;

  const JournalAgentOutputsSection({
    super.key,
    required this.outputs,
    required this.date,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Get agent configs from local files (works offline)
    final agentsAsync = ref.watch(localAgentConfigsProvider);
    final agents = agentsAsync.valueOrNull ?? [];

    // Watch loading status to see if any agents are being pulled
    final loadingStatusAsync = ref.watch(agentLoadingStatusProvider(date));
    final loadingStatuses = loadingStatusAsync.valueOrNull ?? [];

    // Build a map of agent name -> agent config
    final agentMap = <String, DailyAgentConfig>{};
    for (final agent in agents) {
      agentMap[agent.name] = agent;
    }

    // Find agents that are loading (pulling from server)
    final pullingAgents = loadingStatuses
        .where((s) => s.state == AgentLoadingState.pulling || s.state == AgentLoadingState.checking)
        .toList();

    return Column(
      children: [
        // Show loading indicators for agents being pulled
        ...pullingAgents.map((status) => _AgentLoadingCard(status: status)),
        // Show actual outputs
        ...outputs.map((output) {
          // Find the agent config for this output, or create a fallback
          final agentConfig = agentMap[output.agentName] ??
              DailyAgentConfig(
                name: output.agentName,
                displayName: _formatAgentDisplayName(output.agentName),
                description: '',
                scheduleEnabled: false,
                scheduleTime: '',
                outputPath: '',
              );

          return AgentOutputHeader(
            output: output,
            agentConfig: agentConfig,
            initiallyExpanded: false,
          );
        }),
      ],
    );
  }

  /// Format agent name to display name (e.g., "content-scout" -> "Content Scout")
  String _formatAgentDisplayName(String agentName) {
    return agentName
        .split('-')
        .map((word) => word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }
}

/// Loading card for an agent being pulled from server
class _AgentLoadingCard extends StatelessWidget {
  final AgentLoadingStatus status;

  const _AgentLoadingCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isChecking = status.state == AgentLoadingState.checking;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? BrandColors.driftwood.withValues(alpha: 0.3)
              : BrandColors.driftwood.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: BrandColors.forest,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.displayName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  isChecking ? 'Checking for updates...' : 'Loading...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: BrandColors.driftwood,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
