import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/prompt_metadata.dart';
import '../providers/chat_providers.dart';

/// Bottom sheet showing session information and prompt metadata
///
/// Displays:
/// - Session ID
/// - Model being used
/// - Prompt source (default, module, agent, custom)
/// - Context files loaded with token counts
/// - Working directory
/// - Trust mode status
/// - View Full Prompt button to see actual prompt text
class SessionInfoSheet extends ConsumerStatefulWidget {
  final String? sessionId;
  final String? model;
  final String? workingDirectory;
  final PromptMetadata? promptMetadata;
  final List<String> selectedContexts;

  const SessionInfoSheet({
    super.key,
    this.sessionId,
    this.model,
    this.workingDirectory,
    this.promptMetadata,
    this.selectedContexts = const [],
  });

  /// Shows the session info sheet
  static Future<void> show(
    BuildContext context, {
    String? sessionId,
    String? model,
    String? workingDirectory,
    PromptMetadata? promptMetadata,
    List<String> selectedContexts = const [],
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SessionInfoSheet(
        sessionId: sessionId,
        model: model,
        workingDirectory: workingDirectory,
        promptMetadata: promptMetadata,
        selectedContexts: selectedContexts,
      ),
    );
  }

  @override
  ConsumerState<SessionInfoSheet> createState() => _SessionInfoSheetState();
}

class _SessionInfoSheetState extends ConsumerState<SessionInfoSheet> {
  bool _isLoadingPrompt = false;
  String? _promptText;
  String? _promptError;

  Future<void> _loadPrompt() async {
    setState(() {
      _isLoadingPrompt = true;
      _promptError = null;
    });

    try {
      final chatService = ref.read(chatServiceProvider);
      final result = await chatService.getPromptPreview(
        workingDirectory: widget.workingDirectory,
        contexts: widget.selectedContexts.isNotEmpty ? widget.selectedContexts : null,
      );
      setState(() {
        _promptText = result.prompt;
        _isLoadingPrompt = false;
      });
    } catch (e) {
      setState(() {
        _promptError = e.toString();
        _isLoadingPrompt = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
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
                  Icons.info_outline,
                  size: 24,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  _promptText != null ? 'System Prompt' : 'Session Info',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const Spacer(),
                if (_promptText != null)
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _promptText = null;
                      });
                    },
                    icon: Icon(
                      Icons.arrow_back,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    tooltip: 'Back to info',
                  ),
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
          Flexible(
            child: _promptText != null
                ? _buildPromptView(isDark)
                : _buildInfoView(isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoView(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Model Section
          if (widget.model != null) ...[
            _buildInfoRow(
              isDark,
              icon: Icons.smart_toy_outlined,
              label: 'Model',
              value: widget.model!,
              badge: _getModelBadge(widget.model!),
              badgeColor: _getModelColor(widget.model!),
            ),
            const SizedBox(height: Spacing.lg),
          ],

          // Session ID Section
          if (widget.sessionId != null) ...[
            _buildInfoRow(
              isDark,
              icon: Icons.tag,
              label: 'Session ID',
              value: widget.sessionId!,
              copyable: true,
              context: context,
            ),
            const SizedBox(height: Spacing.lg),
          ],

          // Working Directory Section
          if (widget.workingDirectory != null) ...[
            _buildInfoRow(
              isDark,
              icon: Icons.folder_outlined,
              label: 'Working Directory',
              value: widget.workingDirectory!,
              copyable: true,
              context: context,
            ),
            const SizedBox(height: Spacing.lg),
          ],

          // Prompt Metadata Section
          if (widget.promptMetadata != null) ...[
            const Divider(),
            const SizedBox(height: Spacing.lg),

            _buildSectionHeader(isDark, 'System Prompt'),
            const SizedBox(height: Spacing.md),

            // Prompt Source
            _buildInfoRow(
              isDark,
              icon: Icons.article_outlined,
              label: 'Prompt Source',
              value: widget.promptMetadata!.promptSourceDescription,
            ),
            const SizedBox(height: Spacing.md),

            // Token counts
            _buildTokenRow(isDark),
            const SizedBox(height: Spacing.md),

            // Trust Mode
            _buildInfoRow(
              isDark,
              icon: widget.promptMetadata!.trustMode
                  ? Icons.verified_user_outlined
                  : Icons.security_outlined,
              label: 'Trust Mode',
              value: widget.promptMetadata!.trustMode ? 'Enabled' : 'Restricted',
              valueColor: widget.promptMetadata!.trustMode
                  ? BrandColors.success
                  : BrandColors.warning,
            ),

            // Working Directory CLAUDE.md
            if (widget.promptMetadata!.workingDirectoryClaudeMd != null) ...[
              const SizedBox(height: Spacing.md),
              _buildInfoRow(
                isDark,
                icon: Icons.folder_special_outlined,
                label: 'Project Context',
                value: widget.promptMetadata!.workingDirectoryClaudeMd!,
                valueColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ],

            // Context Files Section
            if (widget.promptMetadata!.hasContext) ...[
              const SizedBox(height: Spacing.lg),
              const Divider(),
              const SizedBox(height: Spacing.lg),

              _buildSectionHeader(
                isDark,
                'Context Files (${widget.promptMetadata!.contextFiles.length})',
              ),
              const SizedBox(height: Spacing.sm),

              if (widget.promptMetadata!.contextTruncated)
                Container(
                  margin: const EdgeInsets.only(bottom: Spacing.sm),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: BrandColors.warning.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        size: 14,
                        color: BrandColors.warning,
                      ),
                      const SizedBox(width: Spacing.xs),
                      Text(
                        'Context truncated due to token limit',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: BrandColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),

              ...widget.promptMetadata!.contextFiles.map(
                (file) => _buildContextFileItem(isDark, file),
              ),
            ],

            // Agent Info
            if (widget.promptMetadata!.agentName != null) ...[
              const SizedBox(height: Spacing.lg),
              const Divider(),
              const SizedBox(height: Spacing.lg),

              _buildInfoRow(
                isDark,
                icon: Icons.psychology_outlined,
                label: 'Agent',
                value: widget.promptMetadata!.agentName!,
              ),
            ],
          ],

          // View Full Prompt Button
          const SizedBox(height: Spacing.xl),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isLoadingPrompt ? null : _loadPrompt,
              icon: _isLoadingPrompt
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDark
                            ? BrandColors.nightForest
                            : BrandColors.forest,
                      ),
                    )
                  : const Icon(Icons.visibility_outlined),
              label: Text(
                _isLoadingPrompt ? 'Loading...' : 'View Full Prompt',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                side: BorderSide(
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              ),
            ),
          ),

          if (_promptError != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              _promptError!,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: BrandColors.error,
              ),
            ),
          ],

          // Footer note about transparency
          const SizedBox(height: Spacing.lg),
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
                  Icons.lightbulb_outline,
                  size: 18,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'This information shows what context is being provided to the AI in your conversations.',
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
    );
  }

  Widget _buildPromptView(bool isDark) {
    return Column(
      children: [
        // Copy button row
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Text(
                '${_formatTokens(_promptText!.length ~/ 4)} tokens (estimated)',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _promptText!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Prompt copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
                style: TextButton.styleFrom(
                  foregroundColor:
                      isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Prompt text
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.lg),
            child: SelectableText(
              _promptText!,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                fontFamily: 'monospace',
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(bool isDark, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: TypographyTokens.labelMedium,
        fontWeight: FontWeight.w600,
        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
      ),
    );
  }

  Widget _buildInfoRow(
    bool isDark, {
    required IconData icon,
    required String label,
    required String value,
    String? badge,
    Color? badgeColor,
    Color? valueColor,
    bool copyable = false,
    BuildContext? context,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 18,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(height: Spacing.xxs),
              Row(
                children: [
                  if (badge != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: (badgeColor ?? BrandColors.forest)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: badgeColor ?? BrandColors.forest,
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                  ],
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        color: valueColor ??
                            (isDark
                                ? BrandColors.nightText
                                : BrandColors.charcoal),
                      ),
                    ),
                  ),
                  if (copyable && context != null)
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: value));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied $label'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: Icon(
                        Icons.copy,
                        size: 16,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(Spacing.xs),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTokenRow(bool isDark) {
    final pm = widget.promptMetadata!;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.stone.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          _buildTokenItem(
            isDark,
            'Base Prompt',
            pm.basePromptTokens,
          ),
          _buildTokenDivider(isDark),
          _buildTokenItem(
            isDark,
            'Context',
            pm.contextTokens,
          ),
          _buildTokenDivider(isDark),
          _buildTokenItem(
            isDark,
            'Total',
            pm.totalPromptTokens,
            isTotal: true,
          ),
        ],
      ),
    );
  }

  Widget _buildTokenItem(bool isDark, String label, int tokens, {bool isTotal = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            _formatTokens(tokens),
            style: TextStyle(
              fontSize: isTotal
                  ? TypographyTokens.titleMedium
                  : TypographyTokens.bodyMedium,
              fontWeight: isTotal ? FontWeight.bold : FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTokenDivider(bool isDark) {
    return Container(
      width: 1,
      height: 30,
      color: isDark
          ? BrandColors.nightSurface
          : BrandColors.driftwood.withValues(alpha: 0.2),
    );
  }

  Widget _buildContextFileItem(bool isDark, String filePath) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 16,
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              filePath,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return tokens.toString();
  }

  String _getModelBadge(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) {
      if (lower.contains('4-5') || lower.contains('4.5')) {
        return 'Opus 4.5';
      }
      return 'Opus';
    } else if (lower.contains('sonnet')) {
      if (lower.contains('4')) {
        return 'Sonnet 4';
      }
      return 'Sonnet';
    } else if (lower.contains('haiku')) {
      if (lower.contains('3-5') || lower.contains('3.5')) {
        return 'Haiku 3.5';
      }
      return 'Haiku';
    }
    return model.length > 15 ? model.substring(0, 15) : model;
  }

  Color _getModelColor(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) {
      return const Color(0xFF9333EA); // Purple for Opus
    } else if (lower.contains('sonnet')) {
      return const Color(0xFF3B82F6); // Blue for Sonnet
    } else if (lower.contains('haiku')) {
      return const Color(0xFF14B8A6); // Teal for Haiku
    }
    return BrandColors.forest;
  }
}
