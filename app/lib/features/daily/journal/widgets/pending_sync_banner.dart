import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/journal_providers.dart';

/// Provider for counting pending sync entries
///
/// Returns the total number of entries that are either:
/// - In the pending queue (isPending)
/// - Have pending edits (hasPendingEdit)
final pendingSyncCountProvider = FutureProvider<int>((ref) async {
  try {
    final cache = await ref.watch(journalLocalCacheProvider.future);
    final queue = await ref.watch(pendingQueueProvider.future);

    // Count pending entries from queue
    final queueCount = queue.length;

    // Count pending deletes and edits in cache
    final pendingDeletes = cache.getPendingDeletes().length;
    final pendingEdits = cache.getPendingEdits().length;

    return queueCount + pendingDeletes + pendingEdits;
  } catch (e) {
    return 0;
  }
});

/// Banner showing number of entries pending sync
///
/// Only displays when there are pending entries.
/// Provides a "Retry" button to manually trigger sync.
/// Shows a spinner while sync is in progress.
class PendingSyncBanner extends ConsumerStatefulWidget {
  /// Callback when retry button is pressed. Returns a Future so the
  /// banner can show a syncing indicator while the operation runs.
  final Future<void> Function()? onRetry;

  const PendingSyncBanner({
    super.key,
    this.onRetry,
  });

  @override
  ConsumerState<PendingSyncBanner> createState() => _PendingSyncBannerState();
}

class _PendingSyncBannerState extends ConsumerState<PendingSyncBanner> {
  bool _syncing = false;

  Future<void> _handleRetry() async {
    if (_syncing || widget.onRetry == null) return;
    setState(() => _syncing = true);
    try {
      await widget.onRetry!();
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final countAsync = ref.watch(pendingSyncCountProvider);

    return countAsync.when(
      data: (count) {
        if (count == 0) {
          return const SizedBox.shrink();
        }

        return Material(
          color: BrandColors.driftwood.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '$count ${count == 1 ? 'entry' : 'entries'} pending sync',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: BrandColors.driftwood,
                          fontWeight: FontWeight.w500,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_syncing)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: BrandColors.driftwood,
                      ),
                    ),
                  )
                else
                  TextButton(
                    onPressed: _handleRetry,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(60, 32),
                    ),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (err, st) => const SizedBox.shrink(),
    );
  }
}
