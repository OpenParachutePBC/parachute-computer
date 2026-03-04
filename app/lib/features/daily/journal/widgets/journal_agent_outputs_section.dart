import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/agent_card.dart';
import 'agent_output_header.dart';

/// Section showing agent output cards (reflections, content ideas, etc.)
///
/// Accepts [AgentCard] objects from the graph. Running cards show a spinner;
/// done cards show the expandable [AgentOutputHeader].
class JournalAgentOutputsSection extends StatelessWidget {
  final List<AgentCard> cards;

  const JournalAgentOutputsSection({
    super.key,
    required this.cards,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: cards.map((card) {
        if (card.isRunning) {
          return _AgentRunningCard(card: card);
        }
        return AgentOutputHeader(card: card);
      }).toList(),
    );
  }
}

/// Loading card for an agent currently running
class _AgentRunningCard extends StatelessWidget {
  final AgentCard card;

  const _AgentRunningCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                  card.displayName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Running...',
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
