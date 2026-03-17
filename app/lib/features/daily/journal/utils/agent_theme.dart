import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Shared visual theming for Daily agents.
///
/// Maps agent names to icon, accent color, and contextual running message.
/// Used by AgentOutputHeader, _AgentRunningCard, _AgentFailedCard, etc.
class AgentTheme {
  final IconData icon;
  final Color color;
  final String runningMessage;

  const AgentTheme({
    required this.icon,
    required this.color,
    required this.runningMessage,
  });

  /// Resolve theming for an Agent by name.
  ///
  /// To add a new agent type, add a case here. In the future this could
  /// be driven by server-provided metadata on the Agent node.
  static AgentTheme forAgent(String agentName) {
    switch (agentName) {
      case 'daily-reflection':
        return const AgentTheme(
          icon: Icons.wb_twilight,
          color: BrandColors.forest,
          runningMessage: 'Your reflection is being written\u2026',
        );
      case 'post-process':
        return const AgentTheme(
          icon: Icons.auto_fix_high,
          color: BrandColors.turquoise,
          runningMessage: 'Cleaning up your transcription\u2026',
        );
      default:
        return const AgentTheme(
          icon: Icons.smart_toy_outlined,
          color: BrandColors.driftwood,
          runningMessage: 'Working on something for you\u2026',
        );
    }
  }
}
