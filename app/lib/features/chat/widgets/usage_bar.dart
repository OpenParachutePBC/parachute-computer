import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/claude_usage.dart';
import '../providers/chat_providers.dart';
import '../providers/chat_message_providers.dart' show chatMessagesProvider;

/// Compact usage bar showing Claude usage limits
///
/// Displays 5-hour and weekly usage as progress bars with reset times.
class UsageBar extends ConsumerWidget {
  const UsageBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usageAsync = ref.watch(claudeUsageProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return usageAsync.when(
      data: (usage) {
        if (usage.hasError || !usage.hasData) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
            child: Text(
              'Usage unavailable',
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black38,
                fontSize: 12,
              ),
            ),
          );
        }
        return _UsageContent(usage: usage, isDark: isDark);
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => Padding(
        padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
        child: Text(
          'Usage unavailable',
          style: TextStyle(
            color: isDark ? Colors.white54 : Colors.black38,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _UsageContent extends ConsumerWidget {
  final ClaudeUsage usage;
  final bool isDark;

  const _UsageContent({required this.usage, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurface.withValues(alpha: 0.5)
            : BrandColors.cream.withValues(alpha: 0.8),
        border: Border(
          bottom: BorderSide(
            color: isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.3) : BrandColors.stone,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // 5-hour usage
          if (usage.fiveHour != null)
            Expanded(
              child: _UsageIndicator(
                label: '5h',
                limit: usage.fiveHour!,
                isDark: isDark,
              ),
            ),
          if (usage.fiveHour != null && usage.sevenDay != null)
            SizedBox(width: Spacing.md),
          // Weekly usage
          if (usage.sevenDay != null)
            Expanded(
              child: _UsageIndicator(
                label: '7d',
                limit: usage.sevenDay!,
                isDark: isDark,
              ),
            ),
          // Extra credits if enabled
          if (usage.extraUsage != null && usage.extraUsage!.isEnabled) ...[
            SizedBox(width: Spacing.md),
            _ExtraCreditsIndicator(
              extra: usage.extraUsage!,
              isDark: isDark,
            ),
          ],
          // Active model chip
          const Spacer(),
          _ModelChip(isDark: isDark),
          // Refresh button
          SizedBox(width: Spacing.sm),
          GestureDetector(
            onTap: () => ref.invalidate(claudeUsageProvider),
            child: Icon(
              Icons.refresh,
              size: 14,
              color: textColor.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small chip showing the active model (e.g. "Opus 4.6", "Sonnet 4.6").
/// Reads from ChatMessagesState.model which is set by the SSE model event.
/// Hidden when no model is known yet.
class _ModelChip extends ConsumerWidget {
  final bool isDark;

  const _ModelChip({required this.isDark});

  /// Format "claude-opus-4-6" → "Opus 4.6", "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
  String _label(String modelId) {
    final withoutPrefix = modelId.replaceFirst('claude-', '');
    final parts = withoutPrefix.split('-');
    if (parts.isEmpty || parts[0].isEmpty) return modelId;
    final family = parts[0][0].toUpperCase() + parts[0].substring(1);
    // Version: skip the date part (parts that are purely numeric and long)
    final versionParts = parts.skip(1).where((p) => p.length <= 3).toList();
    if (versionParts.isEmpty) return family;
    return '$family ${versionParts.join('.')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(chatMessagesProvider.select((s) => s.model));
    if (model == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.25)
            : BrandColors.forest.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? BrandColors.nightForest.withValues(alpha: 0.4)
              : BrandColors.forest.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        _label(model),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
        ),
      ),
    );
  }
}

class _UsageIndicator extends StatelessWidget {
  final String label;
  final UsageLimit limit;
  final bool isDark;

  const _UsageIndicator({
    required this.label,
    required this.limit,
    required this.isDark,
  });

  Color _getProgressColor(double utilization) {
    if (utilization >= 90) return BrandColors.error;
    if (utilization >= 70) return BrandColors.warning;
    return isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
  }

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final progressColor = _getProgressColor(limit.utilization);
    final bgColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
        : BrandColors.stone.withValues(alpha: 0.3);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            Text(
              '${limit.utilization.round()}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: progressColor,
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (limit.utilization / 100).clamp(0, 1),
            backgroundColor: bgColor,
            valueColor: AlwaysStoppedAnimation(progressColor),
            minHeight: 4,
          ),
        ),
        if (limit.resetsIn.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              'resets ${limit.resetsIn}',
              style: TextStyle(
                fontSize: 9,
                color: textColor.withValues(alpha: 0.7),
              ),
            ),
          ),
      ],
    );
  }
}

class _ExtraCreditsIndicator extends StatelessWidget {
  final ExtraUsage extra;
  final bool isDark;

  const _ExtraCreditsIndicator({
    required this.extra,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt,
              size: 12,
              color: BrandColors.warning,
            ),
            SizedBox(width: 2),
            Text(
              '\$${extra.remaining.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
        Text(
          'extra left',
          style: TextStyle(
            fontSize: 9,
            color: textColor.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
