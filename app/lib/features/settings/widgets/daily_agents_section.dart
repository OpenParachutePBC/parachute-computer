import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/features/daily/journal/screens/agent_log_screen.dart';

/// Daily agents (scheduler) settings section
class DailyAgentsSection extends ConsumerStatefulWidget {
  const DailyAgentsSection({super.key});

  @override
  ConsumerState<DailyAgentsSection> createState() => _DailyAgentsSectionState();
}

class _DailyAgentsSectionState extends ConsumerState<DailyAgentsSection> {
  bool _isReloadingScheduler = false;
  List<Map<String, dynamic>>? _agents;
  bool _isLoadingAgents = false;
  String? _agentsError;

  @override
  void initState() {
    super.initState();
    // Load agents on first render
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAgents());
  }

  Future<void> _loadAgents() async {
    setState(() {
      _isLoadingAgents = true;
      _agentsError = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.get(
        Uri.parse('$serverUrl/api/modules/daily/agents'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          setState(() {
            _agents = List<Map<String, dynamic>>.from(data['agents'] ?? []);
            _isLoadingAgents = false;
          });
        } else {
          setState(() {
            _agentsError = 'Failed to load agents: ${response.statusCode}';
            _isLoadingAgents = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _agentsError = 'Error: $e';
          _isLoadingAgents = false;
        });
      }
    }
  }

  Future<void> _triggerAgent(String agentName) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Running $agentName...'),
          backgroundColor: BrandColors.turquoise,
        ),
      );

      final response = await http.post(
        Uri.parse('$serverUrl/api/modules/daily/agents/$agentName/run'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: json.encode({'force': true}),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$agentName completed'),
              backgroundColor: BrandColors.success,
            ),
          );
          _loadAgents(); // Refresh to show updated state
        } else {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to run $agentName: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _resetAgent(String agentName) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset $agentName?'),
        content: const Text(
          'This will clear the agent\'s conversation history. '
          'The next run will start fresh without any previous context.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.post(
        Uri.parse('$serverUrl/api/modules/daily/agents/$agentName/reset'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$agentName reset - next run will start fresh'),
              backgroundColor: BrandColors.success,
            ),
          );
          _loadAgents(); // Refresh to show updated state
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to reset: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  void _viewAgentTranscript(String agentName, String displayName) {
    // Navigate to the existing AgentLogScreen which handles transcript display properly
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AgentLogScreen(
          agentName: agentName,
          displayName: displayName,
        ),
      ),
    );
  }

  Future<void> _reloadScheduler() async {
    setState(() => _isReloadingScheduler = true);

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();

      final response = await http.post(
        Uri.parse('$serverUrl/api/scheduler/reload'),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Scheduler reloaded - agents rescanned'),
              backgroundColor: BrandColors.success,
            ),
          );
          // Refresh agents list
          _loadAgents();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to reload: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isReloadingScheduler = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.schedule,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Daily Agents',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
            // Reload button (compact)
            IconButton(
              onPressed: _isReloadingScheduler ? null : () async {
                await _reloadScheduler();
              },
              icon: _isReloadingScheduler
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark ? BrandColors.nightForest : BrandColors.forest,
                        ),
                      ),
                    )
                  : Icon(
                      Icons.refresh,
                      size: 20,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
              tooltip: 'Reload scheduler',
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Scheduled agents run automatically. Reload after adding or editing agents.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Agent list
        if (_isLoadingAgents)
          Center(
            child: Padding(
              padding: EdgeInsets.all(Spacing.lg),
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(
                  isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ),
          )
        else if (_agentsError != null)
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: BrandColors.error),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    _agentsError!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: BrandColors.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loadAgents,
                  child: const Text('Retry'),
                ),
              ],
            ),
          )
        else if (_agents == null || _agents!.isEmpty)
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightSurface : BrandColors.cream),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(
              'No agents found in Daily/.agents/',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          )
        else
          ..._agents!.map((agent) => _buildAgentCard(agent, isDark)),
      ],
    );
  }

  Widget _buildAgentCard(Map<String, dynamic> agent, bool isDark) {
    final name = agent['name'] as String? ?? 'unknown';
    final displayName = agent['displayName'] as String? ?? name;
    final description = agent['description'] as String? ?? '';
    final schedule = agent['schedule'] as Map<String, dynamic>? ?? {};
    final state = agent['state'] as Map<String, dynamic>? ?? {};
    final scheduleTime = schedule['time'] as String? ?? '--:--';
    final scheduleEnabled = schedule['enabled'] as bool? ?? true;
    final lastRunAt = state['lastRunAt'] as String?;
    final runCount = state['runCount'] as int? ?? 0;

    // Format last run time
    String lastRunDisplay = 'Never run';
    if (lastRunAt != null) {
      try {
        final dt = DateTime.parse(lastRunAt);
        final now = DateTime.now();
        final diff = now.difference(dt);
        if (diff.inMinutes < 60) {
          lastRunDisplay = '${diff.inMinutes}m ago';
        } else if (diff.inHours < 24) {
          lastRunDisplay = '${diff.inHours}h ago';
        } else {
          lastRunDisplay = '${diff.inDays}d ago';
        }
      } catch (_) {
        lastRunDisplay = 'Unknown';
      }
    }

    return Container(
      margin: EdgeInsets.only(bottom: Spacing.md),
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightSurface : BrandColors.cream),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: (isDark ? BrandColors.nightForest : BrandColors.forest)
              .withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: name + schedule time
          Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: TypographyTokens.bodyMedium,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: scheduleEnabled
                      ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                          .withValues(alpha: 0.15)
                      : (isDark ? BrandColors.nightSurface : BrandColors.cream),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      scheduleEnabled ? Icons.schedule : Icons.schedule_outlined,
                      size: 12,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                    SizedBox(width: Spacing.xs),
                    Text(
                      scheduleTime,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Description (if any)
          if (description.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              description,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          // Stats row: last run + run count
          SizedBox(height: Spacing.sm),
          Row(
            children: [
              Icon(
                Icons.history,
                size: 12,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              SizedBox(width: Spacing.xs),
              Text(
                '$lastRunDisplay ($runCount runs)',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),

          // Action buttons
          SizedBox(height: Spacing.sm),
          Row(
            children: [
              // Run now button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _triggerAgent(name),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Run'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                  ),
                ),
              ),
              SizedBox(width: Spacing.sm),
              // History button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _viewAgentTranscript(name, displayName),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('History'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                  ),
                ),
              ),
              SizedBox(width: Spacing.sm),
              // Reset button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _resetAgent(name),
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Reset'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                    foregroundColor: BrandColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
