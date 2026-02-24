import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/curator_run.dart';
import '../providers/curator_providers.dart';

/// A small chip in the chat header that shows what the curator did last.
///
/// Appears after the curator has run for the current session. Tappable to
/// show a brief detail dialog about the last run's actions.
///
/// Data flows from: session.metadata["curator_last_run"] → chatMessagesProvider
/// → curatorLastRunProvider → this widget. No polling or push needed — the
/// session is re-fetched after each stream completes.
class CuratorChip extends ConsumerWidget {
  const CuratorChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastRun = ref.watch(curatorLastRunProvider);
    if (lastRun == null) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => _showDetail(context, lastRun),
      child: Container(
        margin: const EdgeInsets.only(right: Spacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: BrandColors.turquoise.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 11,
              color: BrandColors.turquoise,
            ),
            const SizedBox(width: 3),
            Text(
              lastRun.hasChanges ? lastRun.summary : '—',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: BrandColors.turquoise,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, CuratorRun lastRun) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.auto_awesome_outlined, size: 18, color: BrandColors.turquoise),
            const SizedBox(width: Spacing.sm),
            const Text('Curator'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Exchange #${lastRun.exchangeNumber}',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            if (lastRun.actions.isEmpty)
              Text(
                'No changes made',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              )
            else
              ...lastRun.actions.map(
                (action) => Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 14, color: BrandColors.turquoise),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: Text(
                          _actionLabel(action, lastRun),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _actionLabel(String action, CuratorRun run) {
    return switch (action) {
      'update_title' =>
        run.newTitle != null ? 'Updated title → "${run.newTitle}"' : 'Updated title',
      'update_summary' => 'Updated summary',
      'log_activity' => 'Logged activity',
      _ => action,
    };
  }
}
