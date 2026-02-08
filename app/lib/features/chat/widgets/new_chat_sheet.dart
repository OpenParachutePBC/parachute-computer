import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/settings/models/trust_level.dart';
import 'directory_picker.dart';

/// Available agent types for new chats
class AgentOption {
  final String? id; // null = default vault agent
  final String? path; // path to agent definition file
  final String label;
  final String description;
  final IconData icon;

  const AgentOption({
    this.id,
    this.path,
    required this.label,
    required this.description,
    required this.icon,
  });
}

const _availableAgents = [
  AgentOption(
    id: null,
    path: null,
    label: 'Default',
    description: 'Standard vault agent',
    icon: Icons.chat_bubble_outline,
  ),
  AgentOption(
    id: 'orchestrator',
    path: 'Daily/.agents/orchestrator.md',
    label: 'Daily Orchestrator',
    description: 'Thinking partner for your day',
    icon: Icons.auto_awesome,
  ),
];

/// Result from the new chat sheet
class NewChatConfig {
  /// Optional working directory for file operations
  final String? workingDirectory;

  /// Agent type identifier (null = default)
  final String? agentType;

  /// Path to agent definition file
  final String? agentPath;

  /// Trust level override (null = use module default)
  final TrustLevel? trustLevel;

  const NewChatConfig({
    this.workingDirectory,
    this.agentType,
    this.agentPath,
    this.trustLevel,
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
  String? _selectedAgentId; // null = default
  TrustLevel? _selectedTrustLevel; // null = module default
  bool _showAdvanced = false;

  bool get _isSandboxed => _selectedTrustLevel == TrustLevel.sandboxed;

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
                // Agent Type Section
                Text(
                  'Agent',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'Choose which AI agent to chat with',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.sm),

                // Agent selector chips
                Row(
                  children: _availableAgents.map((agent) {
                    final isSelected = _selectedAgentId == agent.id;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: agent != _availableAgents.last ? Spacing.sm : 0,
                        ),
                        child: _buildAgentChip(agent, isSelected, isDark),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: Spacing.lg),

                // Working Directory Section
                Text(
                  _isSandboxed ? 'Sandbox Workspace' : 'Working Directory',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  _isSandboxed
                      ? 'Folder mounted into the sandbox container'
                      : 'Where the AI can read/write files and run commands',
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

                // Sandbox info when sandboxed but no directory
                if (_isSandboxed && !hasDirectory) ...[
                  const SizedBox(height: Spacing.sm),
                  Container(
                    padding: const EdgeInsets.all(Spacing.sm),
                    decoration: BoxDecoration(
                      color: BrandColors.warningLight,
                      borderRadius: BorderRadius.circular(Radii.sm),
                      border: Border.all(
                        color: BrandColors.warning.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: BrandColors.warning,
                        ),
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Text(
                            'Select a folder to mount in the sandbox, or it will use the full vault (read-only).',
                            style: TextStyle(
                              fontSize: TypographyTokens.bodySmall,
                              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Advanced section toggle
                const SizedBox(height: Spacing.md),
                GestureDetector(
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(
                    children: [
                      Icon(
                        _showAdvanced ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      const SizedBox(width: Spacing.xxs),
                      Text(
                        'Advanced',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelMedium,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),

                // Trust level picker (collapsed by default)
                if (_showAdvanced) ...[
                  const SizedBox(height: Spacing.md),
                  Text(
                    'Trust Level',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelMedium,
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Override the module default execution sandbox',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    children: [
                      _buildTrustChip(null, 'Module Default', Icons.settings, isDark),
                      ...TrustLevel.values.map((tl) =>
                        _buildTrustChip(tl, tl.displayName, tl.icon, isDark),
                      ),
                    ],
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
                  onPressed: () {
                    final selectedAgent = _availableAgents.firstWhere(
                      (a) => a.id == _selectedAgentId,
                      orElse: () => _availableAgents.first,
                    );
                    Navigator.pop(
                      context,
                      NewChatConfig(
                        workingDirectory: _workingDirectory,
                        agentType: selectedAgent.id,
                        agentPath: selectedAgent.path,
                        trustLevel: _selectedTrustLevel,
                      ),
                    );
                  },
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(_selectedAgentId == null
                      ? 'Start Chat'
                      : 'Start ${_availableAgents.firstWhere((a) => a.id == _selectedAgentId).label}'),
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

  Widget _buildAgentChip(AgentOption agent, bool isSelected, bool isDark) {
    return GestureDetector(
      onTap: () => setState(() => _selectedAgentId = agent.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? BrandColors.turquoise.withValues(alpha: 0.15)
              : (isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? BrandColors.turquoise : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              agent.icon,
              size: 16,
              color: isSelected
                  ? BrandColors.turquoise
                  : (isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? BrandColors.turquoise
                          : (isDark
                              ? BrandColors.nightText
                              : BrandColors.charcoal),
                    ),
                  ),
                  Text(
                    agent.description,
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrustChip(TrustLevel? level, String label, IconData icon, bool isDark) {
    final isSelected = _selectedTrustLevel == level;
    final color = level?.iconColor(isDark) ??
        (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood);

    return GestureDetector(
      onTap: () => setState(() {
        _selectedTrustLevel = level;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : (isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: isSelected ? color : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? color : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: isSelected ? color : (isDark ? BrandColors.nightText : BrandColors.charcoal),
              ),
            ),
          ],
        ),
      ),
    );
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
