import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'directory_picker.dart';

/// Result from the new chat sheet
class NewChatConfig {
  /// Optional working directory for file operations
  final String? workingDirectory;

  const NewChatConfig({
    this.workingDirectory,
  });

  /// Legacy getter for backwards compatibility - always returns root context
  List<String> get contextFolders => [""];
  List<String> get contexts => contextFolders;
}

/// Bottom sheet for configuring a new chat session
///
/// Allows optionally setting a working directory for the AI to operate in.
/// Context is now handled automatically by the SDK based on the working directory.
class NewChatSheet extends ConsumerStatefulWidget {
  const NewChatSheet({super.key});

  /// Shows the new chat sheet and returns the configuration.
  /// Returns null if cancelled.
  static Future<NewChatConfig?> show(BuildContext context) {
    return showModalBottomSheet<NewChatConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const NewChatSheet(),
    );
  }

  @override
  ConsumerState<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<NewChatSheet> {
  String? _workingDirectory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasDirectory = _workingDirectory != null && _workingDirectory!.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.xl),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: Spacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
              borderRadius: Radii.pill,
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Row(
              children: [
                Icon(
                  Icons.chat_outlined,
                  size: 24,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  'New Chat',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(
                    Icons.close,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Content
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Working Directory Section
                Text(
                  'Working Directory',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'Where the AI can read/write files and run commands',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.sm),

                // Directory selector
                InkWell(
                  onTap: _selectWorkingDirectory,
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Container(
                    padding: const EdgeInsets.all(Spacing.md),
                    decoration: BoxDecoration(
                      color: isDark
                          ? BrandColors.nightSurfaceElevated
                          : BrandColors.stone.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(
                        color: hasDirectory
                            ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          hasDirectory ? Icons.folder_open : Icons.home,
                          size: 20,
                          color: hasDirectory
                              ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                              : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                hasDirectory ? _displayPath(_workingDirectory!) : 'Vault (default)',
                                style: TextStyle(
                                  fontSize: TypographyTokens.bodyMedium,
                                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                                ),
                              ),
                              if (hasDirectory)
                                Text(
                                  _workingDirectory!,
                                  style: TextStyle(
                                    fontSize: TypographyTokens.bodySmall,
                                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ],
                    ),
                  ),
                ),

                // Clear button when directory is set
                if (hasDirectory) ...[
                  const SizedBox(height: Spacing.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _workingDirectory = null),
                      icon: Icon(
                        Icons.clear,
                        size: 16,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      label: Text(
                        'Reset to vault',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const Divider(height: 1),

          // Start Chat button
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    NewChatConfig(
                      workingDirectory: _workingDirectory,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Start Chat'),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        isDark ? BrandColors.nightForest : BrandColors.forest,
                    padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _displayPath(String path) {
    // Show just the last folder name for the title
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  Future<void> _selectWorkingDirectory() async {
    final selected = await showDirectoryPicker(
      context,
      initialPath: _workingDirectory,
    );

    if (selected != null && mounted) {
      setState(() {
        // Empty string means vault root, which we treat as "no custom directory"
        _workingDirectory = selected.isEmpty ? null : selected;
      });
    }
  }
}
