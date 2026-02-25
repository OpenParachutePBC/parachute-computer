import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/curator_providers.dart';
import '../providers/chat_session_providers.dart';
import 'curator_session_viewer_sheet.dart';

/// A small chip in the chat header that shows what the curator did last.
///
/// Tapping opens the full [CuratorSessionViewerSheet] with the curator's
/// conversation history and last-run summary.
class CuratorChip extends ConsumerWidget {
  const CuratorChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastRun = ref.watch(curatorLastRunProvider);
    final sessionId = ref.watch(currentSessionIdProvider);
    if (lastRun == null || sessionId == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => CuratorSessionViewerSheet.show(context, sessionId),
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
            const Icon(
              Icons.auto_awesome_outlined,
              size: 11,
              color: BrandColors.turquoise,
            ),
            const SizedBox(width: 3),
            Text(
              lastRun.hasChanges ? lastRun.summary : '—',
              style: const TextStyle(
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
}
