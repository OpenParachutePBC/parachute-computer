import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/agent_card.dart';
import '../providers/journal_providers.dart';
import '../utils/agent_theme.dart';
import 'agent_output_header.dart';

/// Section showing agent output cards (reflections, content ideas, etc.)
///
/// Accepts [AgentCard] objects from the graph. Routes each card to the
/// appropriate widget based on status: running → shimmer, failed → retry,
/// done → expandable [AgentOutputHeader].
class JournalAgentOutputsSection extends ConsumerWidget {
  final List<AgentCard> cards;

  const JournalAgentOutputsSection({
    super.key,
    required this.cards,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doneCards = cards.where((c) => c.isDone).toList();

    return Column(
      children: cards.map((card) {
        if (card.isRunning) {
          return _AgentRunningCard(card: card);
        }
        if (card.isFailed) {
          return _AgentFailedCard(
            card: card,
            onRetry: () => _retryAgent(ref, card),
          );
        }
        return AgentOutputHeader(
          card: card,
          initiallyExpanded: doneCards.length == 1 && card == doneCards.first,
        );
      }).toList(),
    );
  }

  Future<void> _retryAgent(WidgetRef ref, AgentCard card) async {
    final api = ref.read(dailyApiServiceProvider);
    try {
      await api.triggerAgentRun(card.agentName, date: card.date);
    } catch (e) {
      debugPrint('Retry failed for ${card.agentName}: $e');
    }
    ref.read(journalRefreshTriggerProvider.notifier).state++;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Running Card — shimmer animation with per-agent theming
// ─────────────────────────────────────────────────────────────────────────────

class _AgentRunningCard extends StatefulWidget {
  final AgentCard card;

  const _AgentRunningCard({required this.card});

  @override
  State<_AgentRunningCard> createState() => _AgentRunningCardState();
}

class _AgentRunningCardState extends State<_AgentRunningCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerController;
  late final AgentTheme _agentTheme;

  @override
  void initState() {
    super.initState();
    _agentTheme = AgentTheme.forAgent(widget.card.agentName);
    _shimmerController = AnimationController(
      vsync: this,
      duration: Motion.breathing,
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        // Shimmer sweep position: moves from -1.0 to 2.0 across the card
        final shimmerPosition = _shimmerController.value * 3.0 - 1.0;

        return Container(
          margin: EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
          padding: EdgeInsets.all(Spacing.lg),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(shimmerPosition - 0.5, 0),
              end: Alignment(shimmerPosition + 0.5, 0),
              colors: isDark
                  ? [
                      BrandColors.nightSurfaceElevated,
                      _agentTheme.color.withValues(alpha: 0.08),
                      BrandColors.nightSurfaceElevated,
                    ]
                  : [
                      BrandColors.softWhite,
                      _agentTheme.color.withValues(alpha: 0.06),
                      BrandColors.softWhite,
                    ],
              stops: const [0.0, 0.5, 1.0],
            ),
            borderRadius: Radii.card,
            border: Border.all(
              color: _agentTheme.color.withValues(alpha: isDark ? 0.3 : 0.2),
            ),
          ),
          child: child,
        );
      },
      child: Row(
        children: [
          // Agent icon with subtle pulse
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _agentTheme.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(
              _agentTheme.icon,
              size: 24,
              color: _agentTheme.color,
            ),
          ),
          SizedBox(width: Spacing.md + Spacing.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.card.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _agentTheme.runningMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _agentTheme.color.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Failed Card — gentle error state with tap-to-retry
// ─────────────────────────────────────────────────────────────────────────────

class _AgentFailedCard extends StatelessWidget {
  final AgentCard card;
  final VoidCallback onRetry;

  const _AgentFailedCard({
    required this.card,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final agentTheme = AgentTheme.forAgent(card.agentName);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onRetry,
          borderRadius: Radii.card,
          child: Container(
            padding: EdgeInsets.all(Spacing.lg),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              borderRadius: Radii.card,
              border: Border.all(
                color: BrandColors.error.withValues(alpha: isDark ? 0.3 : 0.2),
              ),
            ),
            child: Row(
              children: [
                // Agent icon with warning tint
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: BrandColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(
                    agentTheme.icon,
                    size: 24,
                    color: BrandColors.error.withValues(alpha: 0.7),
                  ),
                ),
                SizedBox(width: Spacing.md + Spacing.xxs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Couldn\u2019t generate today\u2019s ${card.displayName.toLowerCase()}",
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap to try again',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.refresh,
                  size: 20,
                  color: BrandColors.driftwood,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
