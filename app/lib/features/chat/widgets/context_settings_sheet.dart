import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/prompt_metadata.dart';

/// Bottom sheet for viewing context settings mid-session
///
/// Shows the current working directory and allows reloading CLAUDE.md.
/// Context is now handled automatically by the SDK based on working directory.
class ContextSettingsSheet extends ConsumerWidget {
  final String? workingDirectory;
  final PromptMetadata? promptMetadata;
  final VoidCallback? onReloadClaudeMd;

  const ContextSettingsSheet({
    super.key,
    this.workingDirectory,
    this.promptMetadata,
    this.onReloadClaudeMd,
  });

  /// Shows the context settings sheet
  static Future<void> show(
    BuildContext context, {
    String? workingDirectory,
    PromptMetadata? promptMetadata,
    // Legacy parameters - ignored but kept for compatibility
    List<String>? selectedContexts,
    Function(List<String>)? onContextsChanged,
    VoidCallback? onReloadClaudeMd,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ContextSettingsSheet(
        workingDirectory: workingDirectory,
        promptMetadata: promptMetadata,
        onReloadClaudeMd: onReloadClaudeMd,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final metadata = promptMetadata;
    final claudeMdPath = metadata?.workingDirectoryClaudeMd;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.xl)),
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
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              borderRadius: Radii.pill,
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Row(
              children: [
                Icon(
                  Icons.tune,
                  size: 24,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  'Context Settings',
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
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
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
                _buildSectionHeader(
                  isDark,
                  'Working Directory',
                  'Where the AI can read/write files',
                ),
                const SizedBox(height: Spacing.sm),

                Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isDark
                        ? BrandColors.nightSurfaceElevated
                        : BrandColors.stone.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        workingDirectory != null ? Icons.folder_open : Icons.home,
                        size: 20,
                        color: isDark ? BrandColors.nightForest : BrandColors.forest,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          workingDirectory ?? 'Vault (default)',
                          style: TextStyle(
                            fontSize: TypographyTokens.bodyMedium,
                            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                            fontFamily: workingDirectory != null ? 'monospace' : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Spacing.lg),

                // CLAUDE.md Status Section
                _buildSectionHeader(
                  isDark,
                  'Project Context',
                  'CLAUDE.md loaded from working directory',
                ),
                const SizedBox(height: Spacing.sm),

                Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isDark
                        ? BrandColors.nightSurfaceElevated
                        : BrandColors.stone.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: claudeMdPath != null
                        ? Border.all(
                            color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                                .withValues(alpha: 0.3),
                          )
                        : null,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        claudeMdPath != null ? Icons.check_circle : Icons.info_outline,
                        size: 20,
                        color: claudeMdPath != null
                            ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                            : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              claudeMdPath != null
                                  ? 'CLAUDE.md loaded'
                                  : 'No CLAUDE.md found',
                              style: TextStyle(
                                fontSize: TypographyTokens.bodyMedium,
                                fontWeight: FontWeight.w500,
                                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                              ),
                            ),
                            if (claudeMdPath != null) ...[
                              const SizedBox(height: Spacing.xs),
                              Text(
                                claudeMdPath,
                                style: TextStyle(
                                  fontSize: TypographyTokens.bodySmall,
                                  color: isDark
                                      ? BrandColors.nightTextSecondary
                                      : BrandColors.driftwood,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onReloadClaudeMd != null && claudeMdPath != null)
                        IconButton(
                          onPressed: () {
                            onReloadClaudeMd!();
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Context will refresh on next message'),
                                duration: Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: Icon(
                            Icons.refresh,
                            color: isDark ? BrandColors.nightForest : BrandColors.forest,
                          ),
                          tooltip: 'Reload CLAUDE.md',
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: Spacing.lg),

                // Info text
                Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isDark
                        ? BrandColors.nightSurface
                        : BrandColors.stone.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        size: 16,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          'Context is automatically loaded from CLAUDE.md files in your working directory. '
                          'To change the working directory, start a new chat.',
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom safe area
          SafeArea(
            top: false,
            child: const SizedBox(height: Spacing.sm),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(bool isDark, String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: TypographyTokens.labelMedium,
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
      ],
    );
  }
}
