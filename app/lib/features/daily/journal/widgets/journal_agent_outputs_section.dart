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
///
/// When [showFloatedUnread] is true (default for today's page), also shows
/// unread cards from past days that have floated forward.
class JournalAgentOutputsSection extends ConsumerWidget {
  final List<AgentCard> cards;

  /// When true, fetches and displays unread cards from past days above
  /// today's cards. Only enable on the today journal page.
  final bool showFloatedUnread;

  /// The date string (YYYY-MM-DD) of the current journal page.
  /// Used to filter floated unread cards (exclude today's cards from the
  /// floated section since they already appear in [cards]).
  final String? currentDate;

  const JournalAgentOutputsSection({
    super.key,
    required this.cards,
    this.showFloatedUnread = false,
    this.currentDate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doneCards = cards.where((c) => c.isDone).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Floated unread cards from past days
        if (showFloatedUnread) _FloatedUnreadSection(currentDate: currentDate),

        // Today's cards
        ...cards.map((card) {
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
            onMarkRead: (cardId) => _markRead(ref, cardId),
          );
        }),
      ],
    );
  }

  Future<void> _retryAgent(WidgetRef ref, AgentCard card) async {
    final api = ref.read(dailyApiServiceProvider);
    try {
      await api.triggerAgentRun(card.agentName, date: card.date);
      // Brief pause so the server has time to write the "running" card
      // before we refresh — otherwise we re-fetch the stale "failed" card.
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Retry failed for ${card.agentName}: $e');
    }
    ref.read(journalRefreshTriggerProvider.notifier).state++;
  }

  void _markRead(WidgetRef ref, String cardId) {
    final api = ref.read(dailyApiServiceProvider);
    // Fire and forget — optimistic. Refresh triggers UI update.
    api.markCardRead(cardId).then((_) {
      ref.read(journalRefreshTriggerProvider.notifier).state++;
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Floated Unread Section — unread cards from past days
// ─────────────────────────────────────────────────────────────────────────────

class _FloatedUnreadSection extends ConsumerWidget {
  final String? currentDate;

  const _FloatedUnreadSection({this.currentDate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadAsync = ref.watch(unreadCardsProvider);

    return unreadAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (allUnread) {
        // Filter to past-day cards only (today's cards are already in the main list)
        final floated = currentDate != null
            ? allUnread.where((c) => c.date != currentDate && c.isDone).toList()
            : allUnread.where((c) => c.isDone).toList();

        if (floated.isEmpty) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.sm,
              ),
              child: Text(
                'Earlier',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: BrandColors.driftwood,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ...floated.map((card) => _FloatedCardWrapper(
                  card: card,
                  isDark: isDark,
                  onMarkRead: (cardId) {
                    final api = ref.read(dailyApiServiceProvider);
                    api.markCardRead(cardId).then((_) {
                      ref.read(journalRefreshTriggerProvider.notifier).state++;
                    });
                  },
                )),
            SizedBox(height: Spacing.md),
          ],
        );
      },
    );
  }
}

/// Wraps an [AgentOutputHeader] for a floated card, adding the source date.
class _FloatedCardWrapper extends StatelessWidget {
  final AgentCard card;
  final bool isDark;
  final void Function(String cardId) onMarkRead;

  const _FloatedCardWrapper({
    required this.card,
    required this.isDark,
    required this.onMarkRead,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Format the source date nicely (e.g., "Mar 22")
    String dateLabel = card.date;
    try {
      final parsed = DateTime.parse(card.date);
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      dateLabel = '${months[parsed.month - 1]} ${parsed.day}';
    } catch (_) {}

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: Spacing.lg + 4, bottom: 2),
          child: Text(
            dateLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: BrandColors.driftwood,
              fontSize: 11,
            ),
          ),
        ),
        AgentOutputHeader(
          card: card,
          onMarkRead: onMarkRead,
        ),
      ],
    );
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
            child: Icon(_agentTheme.icon, size: 24, color: _agentTheme.color),
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

class _AgentFailedCard extends StatefulWidget {
  final AgentCard card;
  final Future<void> Function() onRetry;

  const _AgentFailedCard({required this.card, required this.onRetry});

  @override
  State<_AgentFailedCard> createState() => _AgentFailedCardState();
}

class _AgentFailedCardState extends State<_AgentFailedCard> {
  bool _retrying = false;

  Future<void> _handleTap() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      // Reset after the API call completes (success or failure).
      // The card will either disappear (replaced by running card on
      // next refresh) or stay failed — either way, re-enable the button.
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final agentTheme = AgentTheme.forAgent(widget.card.agentName);

    // Once retrying, show the same style as the running card
    final accentColor = _retrying ? agentTheme.color : BrandColors.error;
    final borderColor = _retrying
        ? agentTheme.color.withValues(alpha: isDark ? 0.3 : 0.2)
        : BrandColors.error.withValues(alpha: isDark ? 0.3 : 0.2);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _retrying ? null : _handleTap,
          borderRadius: Radii.card,
          child: Container(
            padding: EdgeInsets.all(Spacing.lg),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.softWhite,
              borderRadius: Radii.card,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(
                      alpha: _retrying ? 0.15 : 0.1,
                    ),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(
                    agentTheme.icon,
                    size: 24,
                    color: _retrying
                        ? accentColor
                        : accentColor.withValues(alpha: 0.7),
                  ),
                ),
                SizedBox(width: Spacing.md + Spacing.xxs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _retrying
                            ? widget.card.displayName
                            : "Couldn\u2019t generate today\u2019s ${widget.card.displayName.toLowerCase()}",
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _retrying
                            ? 'Retrying\u2026 this may take a few minutes'
                            : 'Tap to try again',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_retrying)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: agentTheme.color.withValues(alpha: 0.6),
                    ),
                  )
                else
                  Icon(Icons.refresh, size: 20, color: BrandColors.driftwood),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
