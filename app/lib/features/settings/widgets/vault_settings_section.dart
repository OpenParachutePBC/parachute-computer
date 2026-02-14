import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import 'package:parachute/features/chat/providers/chat_providers.dart';

/// Vault path and folder settings section
class VaultSettingsSection extends ConsumerStatefulWidget {
  final String vaultPath;
  final String dailyFolderName;
  final String chatFolderName;
  final bool showChatFolder;
  final VoidCallback onVaultChanged;

  const VaultSettingsSection({
    super.key,
    required this.vaultPath,
    required this.dailyFolderName,
    required this.chatFolderName,
    required this.showChatFolder,
    required this.onVaultChanged,
  });

  @override
  ConsumerState<VaultSettingsSection> createState() => _VaultSettingsSectionState();
}

class _VaultSettingsSectionState extends ConsumerState<VaultSettingsSection> {
  Future<void> _openFolder(String path) async {
    try {
      // Resolve ~ to home directory
      String resolvedPath = path;
      if (path.startsWith('~')) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          resolvedPath = path.replaceFirst('~', home);
        }
      }

      final uri = Uri.file(resolvedPath);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Could not open folder'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _changeVaultFolder() async {
    final dailyService = ref.read(dailyFileSystemServiceProvider);
    final chatService = ref.read(chatFileSystemServiceProvider);

    // Handle Android permissions
    if (Platform.isAndroid) {
      final hasPermission = await dailyService.hasStoragePermission();
      if (!hasPermission) {
        final granted = await dailyService.requestStoragePermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Storage permission required'),
                backgroundColor: BrandColors.error,
              ),
            );
          }
          return;
        }
      }
    }

    debugPrint('[Settings] Opening folder picker...');

    try {
      final selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose Parachute Folder',
      );

      debugPrint('[Settings] Folder picker returned: $selectedDirectory');

      if (selectedDirectory != null) {
        // Update both services to use the same vault location
        final dailySuccess = await dailyService.setVaultPath(selectedDirectory, migrateFiles: false);
        final chatSuccess = await chatService.setVaultPath(selectedDirectory, migrateFiles: false);

        if (dailySuccess && chatSuccess) {
          // Invalidate all providers that depend on file paths so they refresh
          ref.invalidate(journalServiceFutureProvider);
          ref.invalidate(todayJournalProvider);
          ref.invalidate(selectedJournalProvider);
          ref.invalidate(journalDatesProvider);
          ref.invalidate(chatLogServiceFutureProvider);
          ref.invalidate(selectedChatLogProvider);
          ref.invalidate(reflectionServiceFutureProvider);
          ref.invalidate(selectedReflectionProvider);
          ref.invalidate(dailyRootPathProvider);
          ref.invalidate(chatRootPathProvider);

          widget.onVaultChanged();

          if (mounted) {
            final displayPath = await dailyService.getVaultPathDisplay();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Parachute vault: $displayPath'),
                backgroundColor: BrandColors.success,
              ),
            );
          }
        }
      } else {
        debugPrint('[Settings] User cancelled folder picker or picker failed');
      }
    } catch (e, stackTrace) {
      debugPrint('[Settings] Error in folder picker: $e');
      debugPrint('[Settings] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening folder picker: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.folder_special,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Parachute Vault',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Your Parachute data is stored locally in this folder.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Vault path display
        Container(
          padding: EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, size: 20),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  widget.vaultPath,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: Spacing.md),

        // Subfolder info
        Container(
          padding: EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: (isDark ? BrandColors.nightSurface : BrandColors.cream)
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FolderInfoRow(
                icon: Icons.wb_sunny,
                iconColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                folderName: widget.dailyFolderName,
                description: 'journals & recordings',
                isDark: isDark,
              ),
              if (widget.showChatFolder) ...[
                SizedBox(height: Spacing.xs),
                _FolderInfoRow(
                  icon: Icons.chat_bubble,
                  iconColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  folderName: widget.chatFolderName,
                  description: 'AI sessions & content',
                  isDark: isDark,
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: Spacing.lg),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _changeVaultFolder,
                icon: const Icon(Icons.folder, size: 18),
                label: const Text('Change'),
              ),
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _openFolder(widget.vaultPath),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open'),
                style: FilledButton.styleFrom(
                  backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Row showing module folder info within the vault
class _FolderInfoRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String folderName;
  final String description;
  final bool isDark;

  const _FolderInfoRow({
    required this.icon,
    required this.iconColor,
    required this.folderName,
    required this.description,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor),
        SizedBox(width: Spacing.xs),
        Text(
          folderName,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        Text(
          '/',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            description,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
