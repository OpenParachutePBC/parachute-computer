import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import '../models/prompt_metadata.dart';
import '../providers/container_providers.dart';

/// Unified bottom sheet that consolidates session context and info
/// into a single scrollable sheet.
///
/// Sections:
///   1. Header - title, workspace badge, model badge, agent badge
///   2. Workspace - name display or promotion banner for unnamed sandboxes
///   3. Context - working directory and CLAUDE.md status
///   4. Capabilities - agents, skills, MCPs
///   5. Session Info - ID, model, tokens, prompt source
class UnifiedSessionSettings extends ConsumerStatefulWidget {
  final ChatSession session;
  final String? model;
  final String? workingDirectory;
  final PromptMetadata? promptMetadata;
  final List<String> selectedContexts;
  final VoidCallback? onReloadClaudeMd;
  final VoidCallback? onConfigSaved;

  const UnifiedSessionSettings({
    super.key,
    required this.session,
    this.model,
    this.workingDirectory,
    this.promptMetadata,
    this.selectedContexts = const [],
    this.onReloadClaudeMd,
    this.onConfigSaved,
  });

  /// Shows the unified settings sheet as a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required ChatSession session,
    String? model,
    String? workingDirectory,
    PromptMetadata? promptMetadata,
    List<String> selectedContexts = const [],
    VoidCallback? onReloadClaudeMd,
    VoidCallback? onConfigSaved,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => UnifiedSessionSettings(
        session: session,
        model: model,
        workingDirectory: workingDirectory,
        promptMetadata: promptMetadata,
        selectedContexts: selectedContexts,
        onReloadClaudeMd: onReloadClaudeMd,
        onConfigSaved: onConfigSaved,
      ),
    );
  }

  @override
  ConsumerState<UnifiedSessionSettings> createState() =>
      _UnifiedSessionSettingsState();
}

class _UnifiedSessionSettingsState
    extends ConsumerState<UnifiedSessionSettings> {
  final _workspaceNameController = TextEditingController();
  bool _isNamingWorkspace = false;

  @override
  void dispose() {
    _workspaceNameController.dispose();
    super.dispose();
  }

  Future<void> _nameWorkspace(String slug) async {
    final name = _workspaceNameController.text.trim();
    if (name.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isNamingWorkspace = true);
    try {
      final service = ref.read(containerServiceProvider);
      await service.updateContainer(slug, displayName: name);
      ref.invalidate(containersProvider);
      ref.invalidate(allContainersProvider);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Workspace named "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to name workspace: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isNamingWorkspace = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = widget.session;
    final metadata = widget.promptMetadata;
    final claudeMdPath = metadata?.workingDirectoryClaudeMd ?? metadata?.promptSourcePath;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
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

          // Header row with close button
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.lg, Spacing.md, Spacing.sm, 0),
            child: Row(
              children: [
                Icon(
                  Icons.settings_outlined,
                  size: 22,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Session Settings',
                    style: TextStyle(
                      fontSize: TypographyTokens.titleLarge,
                      fontWeight: FontWeight.w600,
                      color:
                          isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
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

          const Divider(height: Spacing.lg),

          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.lg, 0, Spacing.lg, Spacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- Section 1: Header badges ---
                  _buildHeaderBadges(isDark, session),

                  const SizedBox(height: Spacing.lg),
                  _divider(isDark),
                  const SizedBox(height: Spacing.lg),

                  // --- Section 2: Workspace ---
                  if (session.containerId != null)
                    _buildWorkspaceSection(isDark, session.containerId!),

                  if (session.containerId != null) ...[
                    const SizedBox(height: Spacing.lg),
                    _divider(isDark),
                    const SizedBox(height: Spacing.lg),
                  ],

                  // --- Section 3: Context ---
                  _buildContextSection(isDark, claudeMdPath),

                  // --- Section 3.5: Active Capabilities ---
                  if (metadata != null && _hasCapabilities(metadata)) ...[
                    const SizedBox(height: Spacing.lg),
                    _divider(isDark),
                    const SizedBox(height: Spacing.lg),
                    _buildCapabilitiesSection(isDark, metadata),
                  ],

                  const SizedBox(height: Spacing.lg),
                  _divider(isDark),
                  const SizedBox(height: Spacing.lg),

                  // --- Section 4: Session Info ---
                  _buildSessionInfoSection(isDark, metadata),

                  // Bottom safe area padding
                  SizedBox(
                      height: MediaQuery.of(context).padding.bottom +
                          Spacing.sm),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Header badges ----

  Widget _buildHeaderBadges(bool isDark, ChatSession session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Session title
        Text(
          session.displayTitle,
          style: TextStyle(
            fontSize: TypographyTokens.titleMedium,
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: Spacing.sm),

        // Badge row
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [
            // Model badge
            if (widget.model != null)
              _badge(
                _getModelBadge(widget.model!),
                _getModelColor(widget.model!),
              ),
            // Agent badge
            if (session.agentDisplayName != null)
              _badge(
                session.agentDisplayName!,
                isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            // Source badge for bot sessions
            if (session.source.isBotSession)
              _badge(
                session.source.displayName,
                session.source == ChatSource.telegram
                    ? const Color(0xFF0088CC)
                    : const Color(0xFF5865F2),
              ),
            // Workspace badge
            if (widget.workingDirectory != null)
              _badge(
                widget.workingDirectory!.split('/').last,
                isDark ? BrandColors.nightForest : BrandColors.forest,
                icon: Icons.folder_outlined,
              ),
          ],
        ),
      ],
    );
  }

  Widget _badge(String label, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: Spacing.xs),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ---- Workspace Section ----

  Widget _buildWorkspaceSection(bool isDark, String containerSlug) {
    final allContainers = ref.watch(allContainersProvider);
    final container = allContainers.whenOrNull(
      data: (all) => all.where((e) => e.slug == containerSlug).firstOrNull,
    );

    final isNamed = container?.isWorkspace == true;
    final displayName = container?.displayName ?? containerSlug;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isDark, 'Workspace'),
        const SizedBox(height: Spacing.sm),
        if (isNamed) ...[
          // Named workspace — show name with edit option
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
                  Icons.dns_outlined,
                  size: 18,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodyMedium,
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? BrandColors.nightText
                              : BrandColors.charcoal,
                        ),
                      ),
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        containerSlug,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          fontFamily: 'monospace',
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          // Unnamed sandbox — show promotion banner
          Container(
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                    .withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
Icon(
                      Icons.dns_outlined,
                      size: 16,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'Unnamed sandbox',
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
                const SizedBox(height: Spacing.sm),
                Text(
                  'Name this workspace to find it easily in the sidebar.',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _workspaceNameController,
                          decoration: InputDecoration(
                            hintText: 'Workspace name',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: Spacing.sm,
                              vertical: Spacing.xs,
                            ),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(Spacing.xs),
                            ),
                          ),
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: isDark
                                ? BrandColors.nightText
                                : BrandColors.ink,
                          ),
                          onSubmitted: (_) => _nameWorkspace(containerSlug),
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    SizedBox(
                      height: 36,
                      child: FilledButton(
                        onPressed: _isNamingWorkspace
                            ? null
                            : () => _nameWorkspace(containerSlug),
                        style: FilledButton.styleFrom(
                          backgroundColor: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                          padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.md),
                        ),
                        child: _isNamingWorkspace
                            ? const SizedBox(
                                height: 14,
                                width: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Name'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ---- Context Section ----

  Widget _buildContextSection(bool isDark, String? claudeMdPath) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isDark, 'Context'),
        const SizedBox(height: Spacing.sm),

        // Working directory
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
                widget.workingDirectory != null
                    ? Icons.folder_open
                    : Icons.home,
                size: 18,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  widget.workingDirectory ?? 'Vault (default)',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    color:
                        isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontFamily:
                        widget.workingDirectory != null ? 'monospace' : null,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: Spacing.sm),

        // CLAUDE.md status
        Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: isDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.stone.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(Radii.md),
            border: claudeMdPath != null
                ? Border.all(
                    color: (isDark
                            ? BrandColors.nightForest
                            : BrandColors.forest)
                        .withValues(alpha: 0.3),
                  )
                : null,
          ),
          child: Row(
            children: [
              Icon(
                claudeMdPath != null ? Icons.check_circle : Icons.info_outline,
                size: 18,
                color: claudeMdPath != null
                    ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                    : (isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood),
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
                        fontSize: TypographyTokens.bodySmall,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                      ),
                    ),
                    if (claudeMdPath != null) ...[
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        claudeMdPath,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
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
              if (widget.onReloadClaudeMd != null && claudeMdPath != null)
                IconButton(
                  onPressed: () {
                    widget.onReloadClaudeMd!();
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Context will refresh on next message'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: Icon(
                    Icons.refresh,
                    size: 20,
                    color:
                        isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  tooltip: 'Reload CLAUDE.md',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(Spacing.xs),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Capabilities Section ----

  bool _hasCapabilities(PromptMetadata metadata) {
    return metadata.availableAgents.isNotEmpty ||
        metadata.availableSkills.isNotEmpty ||
        metadata.availableMcps.isNotEmpty;
  }

  Widget _buildCapabilitiesSection(bool isDark, PromptMetadata metadata) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isDark, 'Active Capabilities'),
        const SizedBox(height: Spacing.sm),
        if (metadata.availableAgents.isNotEmpty)
          _capabilityRow(
            isDark,
            Icons.smart_toy_outlined,
            'Agents',
            metadata.availableAgents,
          ),
        if (metadata.availableSkills.isNotEmpty) ...[
          if (metadata.availableAgents.isNotEmpty)
            const SizedBox(height: Spacing.sm),
          _capabilityRow(
            isDark,
            Icons.bolt_outlined,
            'Skills',
            metadata.availableSkills,
          ),
        ],
        if (metadata.availableMcps.isNotEmpty) ...[
          if (metadata.availableAgents.isNotEmpty ||
              metadata.availableSkills.isNotEmpty)
            const SizedBox(height: Spacing.sm),
          _capabilityRow(
            isDark,
            Icons.dns_outlined,
            'MCP Servers',
            metadata.availableMcps,
          ),
        ],
      ],
    );
  }

  Widget _capabilityRow(
    bool isDark,
    IconData icon,
    String label,
    List<String> items,
  ) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.stone.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                '$label (${items.length})',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: items.map((name) => Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightForest.withValues(alpha: 0.15)
                    : BrandColors.forestMist,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            )).toList(),
          ),
        ],
      ),
    );
  }

  // ---- Session Info Section ----

  Widget _buildSessionInfoSection(bool isDark, PromptMetadata? metadata) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isDark, 'Session Info'),
        const SizedBox(height: Spacing.sm),

        // Session ID
        _infoRow(
          isDark,
          Icons.tag,
          'Session ID',
          widget.session.id,
          copyable: true,
        ),
        const SizedBox(height: Spacing.sm),

        // Created
        _infoRow(
          isDark,
          Icons.schedule,
          'Created',
          _formatDateTime(widget.session.createdAt),
        ),
        const SizedBox(height: Spacing.sm),

        // Messages
        _infoRow(
          isDark,
          Icons.chat_bubble_outline,
          'Messages',
          '${widget.session.messageCount}',
        ),

        // Token counts from metadata
        if (metadata != null) ...[
          const SizedBox(height: Spacing.sm),
          _buildTokenRow(isDark, metadata),
        ],
      ],
    );
  }

  // ---- Helpers ----

  Widget _sectionLabel(bool isDark, String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: TypographyTokens.labelMedium,
        fontWeight: FontWeight.w600,
        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
      ),
    );
  }

  Widget _divider(bool isDark) {
    return Divider(
      height: 1,
      color: isDark
          ? BrandColors.nightSurfaceElevated
          : BrandColors.stone.withValues(alpha: 0.5),
    );
  }

  Widget _infoRow(
    bool isDark,
    IconData icon,
    String label,
    String value, {
    bool copyable = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 16,
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
              Text(
                value,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
        ),
        if (copyable)
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
              size: 14,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(Spacing.xs),
          ),
      ],
    );
  }

  Widget _buildTokenRow(bool isDark, PromptMetadata pm) {
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
          _tokenItem(isDark, 'Base', pm.basePromptTokens),
          _tokenDivider(isDark),
          _tokenItem(isDark, 'Context', pm.contextTokens),
          _tokenDivider(isDark),
          _tokenItem(isDark, 'Total', pm.totalPromptTokens, isTotal: true),
        ],
      ),
    );
  }

  Widget _tokenItem(bool isDark, String label, int tokens,
      {bool isTotal = false}) {
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

  Widget _tokenDivider(bool isDark) {
    return Container(
      width: 1,
      height: 30,
      color: isDark
          ? BrandColors.nightSurface
          : BrandColors.driftwood.withValues(alpha: 0.2),
    );
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}k';
    return tokens.toString();
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _getModelBadge(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) {
      if (lower.contains('4-5') || lower.contains('4.5')) return 'Opus 4.5';
      if (lower.contains('4-6') || lower.contains('4.6')) return 'Opus 4.6';
      return 'Opus';
    } else if (lower.contains('sonnet')) {
      if (lower.contains('4-5') || lower.contains('4.5')) return 'Sonnet 4.5';
      if (lower.contains('4')) return 'Sonnet 4';
      return 'Sonnet';
    } else if (lower.contains('haiku')) {
      if (lower.contains('4-5') || lower.contains('4.5')) return 'Haiku 4.5';
      return 'Haiku';
    }
    return model.length > 15 ? model.substring(0, 15) : model;
  }

  Color _getModelColor(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) return const Color(0xFF9333EA);
    if (lower.contains('sonnet')) return const Color(0xFF3B82F6);
    if (lower.contains('haiku')) return const Color(0xFF14B8A6);
    return BrandColors.forest;
  }
}
