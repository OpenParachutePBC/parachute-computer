import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/chat/services/chat_service.dart';
import 'package:parachute/features/chat/providers/chat_providers.dart' show chatServiceProvider;

/// Session migration settings section
class MigrationSection extends ConsumerWidget {
  const MigrationSection({super.key});

  Future<void> _scanMigration(BuildContext context, WidgetRef ref, bool isDark) async {
    final chatService = ref.read(chatServiceProvider);

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
              ),
            ),
            SizedBox(width: Spacing.md),
            const Text('Scanning sessions...'),
          ],
        ),
        duration: const Duration(seconds: 30),
      ),
    );

    final result = await chatService.scanMigration();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Failed to scan sessions. Check server connection.'),
          backgroundColor: BrandColors.error,
        ),
      );
      return;
    }

    // Show results dialog
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Migration Scan Results'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Current vault: ${result.currentVaultRoot}'),
              SizedBox(height: Spacing.md),
              Text('Total sessions: ${result.total}'),
              Text('Already current: ${result.alreadyCurrent}'),
              Text('No vault root: ${result.noVaultRoot}'),
              SizedBox(height: Spacing.md),
              Text(
                'Needs migration: ${result.needsMigration.length}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: result.needsMigration.isNotEmpty ? BrandColors.warning : BrandColors.success,
                ),
              ),
              if (result.needsMigration.isNotEmpty) ...[
                SizedBox(height: Spacing.md),
                const Text('Sessions to migrate:', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: Spacing.sm),
                ...result.needsMigration.take(10).map((s) => Padding(
                  padding: EdgeInsets.only(bottom: Spacing.xs),
                  child: Text(
                    '• ${s.title} (from ${s.oldVaultRoot})',
                    style: TextStyle(fontSize: TypographyTokens.bodySmall),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
                if (result.needsMigration.length > 10)
                  Text('...and ${result.needsMigration.length - 10} more'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (result.needsMigration.isNotEmpty)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _runMigration(context, ref, isDark);
              },
              child: const Text('Migrate All'),
            ),
        ],
      ),
    );
  }

  Future<void> _runMigration(BuildContext context, WidgetRef ref, bool isDark) async {
    final chatService = ref.read(chatServiceProvider);

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
              ),
            ),
            SizedBox(width: Spacing.md),
            const Text('Migrating sessions...'),
          ],
        ),
        duration: const Duration(minutes: 5),
      ),
    );

    final result = await chatService.migrateAllSessions();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Migration failed: ${result.error}'),
          backgroundColor: BrandColors.error,
        ),
      );
      return;
    }

    if (result.total == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No sessions need migration!'),
          backgroundColor: BrandColors.success,
        ),
      );
      return;
    }

    // Show results
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Migration Complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Migrated: ${result.migrated} sessions'),
            if (result.failed > 0)
              Text(
                'Failed: ${result.failed} sessions',
                style: TextStyle(color: BrandColors.error),
              ),
            SizedBox(height: Spacing.md),
            const Text('You can now open your migrated chats.'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.sync_alt,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Session Migration',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.md),
        Text(
          'Migrate sessions from a different machine or vault location to work properly on this device.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _scanMigration(context, ref, isDark),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Scan for Issues'),
            ),
            SizedBox(width: Spacing.md),
            FilledButton.icon(
              onPressed: () => _runMigration(context, ref, isDark),
              icon: const Icon(Icons.healing, size: 18),
              label: const Text('Migrate All'),
            ),
          ],
        ),
      ],
    );
  }
}
