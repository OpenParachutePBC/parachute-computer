import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/journal_providers.dart';

/// Empty state view when no journal entries exist
class JournalEmptyState extends ConsumerWidget {
  final bool isToday;

  const JournalEmptyState({
    super.key,
    required this.isToday,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isToday ? Icons.wb_sunny_outlined : Icons.history,
              size: 64,
              color: isDark ? BrandColors.driftwood : BrandColors.stone,
            ),
            const SizedBox(height: 16),
            Text(
              isToday ? 'Start your day' : 'No entries',
              style: theme.textTheme.titleLarge?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.charcoal,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isToday
                  ? 'Capture a thought, record a voice note,\nor just write something down.'
                  : 'No journal entries for this day.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
            if (!isToday) ...[
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: () {
                  // Go to today
                  ref.read(selectedJournalDateProvider.notifier).state = DateTime.now();
                },
                icon: const Icon(Icons.today),
                label: const Text('Go to Today'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state view when loading fails
class JournalErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const JournalErrorState({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: BrandColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleLarge?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
