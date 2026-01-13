import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/base_server_provider.dart';
import 'package:parachute/core/services/base_server_service.dart';
import '../providers/journal_providers.dart';
import '../screens/curator_log_screen.dart';

/// Card that allows triggering the daily curator to generate a reflection.
///
/// Shows different states:
/// - Server not connected: shows connection status
/// - No reflection: shows button to generate
/// - Generating: shows progress
/// - Error: shows error message
class CuratorTriggerCard extends ConsumerWidget {
  final DateTime date;
  final VoidCallback? onReflectionGenerated;

  const CuratorTriggerCard({
    super.key,
    required this.date,
    this.onReflectionGenerated,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Watch server connectivity
    final serverConnected = ref.watch(serverConnectedProvider);
    final curatorState = ref.watch(curatorTriggerProvider);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? BrandColors.charcoal.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
      ),
      child: serverConnected.when(
        data: (connected) {
          if (!connected) {
            return _buildDisconnectedState(context, isDark);
          }
          return curatorState.when(
            data: (result) {
              if (result == null) {
                return _buildReadyState(context, ref, isDark);
              }
              if (result.success) {
                return _buildSuccessState(context, ref, result, isDark);
              }
              return _buildErrorState(context, ref, result, isDark);
            },
            loading: () => _buildLoadingState(context, isDark),
            error: (e, _) => _buildErrorState(
              context,
              ref,
              CuratorRunResult.error(e.toString()),
              isDark,
            ),
          );
        },
        loading: () => _buildCheckingState(context, isDark),
        error: (e, _) => _buildDisconnectedState(context, isDark),
      ),
    );
  }

  Widget _buildCheckingState(BuildContext context, bool isDark) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'Checking server connection...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedState(BuildContext context, bool isDark) {
    return Row(
      children: [
        Icon(
          Icons.cloud_off,
          size: 20,
          color: BrandColors.driftwood,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Base server not connected',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                ),
              ),
              Text(
                'Start the Parachute Base server to generate reflections',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReadyState(BuildContext context, WidgetRef ref, bool isDark) {
    final dateStr = _formatDate(date);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 20,
              color: BrandColors.forest,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Generate Morning Reflection',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // View log button
            IconButton(
              icon: Icon(
                Icons.history,
                size: 20,
                color: BrandColors.driftwood,
              ),
              onPressed: () => _openCuratorLog(context),
              tooltip: 'View curator log',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Create an AI reflection based on your journal entries',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _triggerCurator(ref, dateStr),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Generate'),
            style: FilledButton.styleFrom(
              backgroundColor: BrandColors.forest,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openCuratorLog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const CuratorLogScreen(),
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
              child: Text(
                'Generating reflection...',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'The AI curator is reviewing your journal entries',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          backgroundColor: isDark
              ? BrandColors.charcoal
              : BrandColors.stone.withValues(alpha: 0.3),
          color: BrandColors.forest,
        ),
      ],
    );
  }

  Widget _buildSuccessState(
    BuildContext context,
    WidgetRef ref,
    CuratorRunResult result,
    bool isDark,
  ) {
    // Notify parent that reflection was generated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onReflectionGenerated?.call();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.check_circle,
              size: 20,
              color: BrandColors.forest,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                result.skipped ? 'Already generated' : 'Reflection created!',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        if (result.message != null) ...[
          const SizedBox(height: 8),
          Text(
            result.message!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: BrandColors.driftwood,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: () {
            ref.read(curatorTriggerProvider.notifier).reset();
            ref.invalidate(selectedReflectionProvider);
          },
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildErrorState(
    BuildContext context,
    WidgetRef ref,
    CuratorRunResult result,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.error_outline,
              size: 20,
              color: BrandColors.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Failed to generate reflection',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          result.error ?? 'Unknown error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: () {
                ref.read(curatorTriggerProvider.notifier).reset();
              },
              child: const Text('Dismiss'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _triggerCurator(ref, _formatDate(date)),
              style: FilledButton.styleFrom(
                backgroundColor: BrandColors.forest,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ],
    );
  }

  void _triggerCurator(WidgetRef ref, String dateStr) {
    ref.read(curatorTriggerProvider.notifier).trigger(date: dateStr);
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
