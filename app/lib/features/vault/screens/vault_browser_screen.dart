import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/features/vault/screens/files_screen.dart';
import 'package:parachute/features/vault/screens/remote_files_screen.dart';

/// Vault Browser Screen - file explorer for ~/Parachute
///
/// Shows:
/// - File tree for Daily and Chat folders
/// - Quick access to recent files
/// - Search across vault
///
/// Can work in offline mode (browsing local Daily folder)
/// or with server connection for full remote vault access.
class VaultBrowserScreen extends ConsumerWidget {
  const VaultBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final serverUrlAsync = ref.watch(aiServerUrlProvider);

    return serverUrlAsync.when(
      data: (serverUrl) {
        // If server URL is configured, use remote file browser
        if (serverUrl.isNotEmpty) {
          return const RemoteFilesScreen();
        }
        // Otherwise show local files with offline banner
        return _buildWithOfflineBanner(context, isDark);
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _buildWithOfflineBanner(context, isDark),
    );
  }

  Widget _buildWithOfflineBanner(BuildContext context, bool isDark) {
    return Column(
      children: [
        // Offline mode banner
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          color: isDark
              ? BrandColors.warning.withValues(alpha: 0.2)
              : BrandColors.warning.withValues(alpha: 0.1),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 18,
                color: BrandColors.warning,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'Offline mode - browsing local Daily folder',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: BrandColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ),
        // File browser
        const Expanded(child: FilesScreen()),
      ],
    );
  }
}
