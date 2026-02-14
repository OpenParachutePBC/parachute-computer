import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import '../../settings/models/trust_level.dart';
import '../models/chat_session.dart';
import '../models/prompt_metadata.dart';

/// Unified bottom sheet that consolidates session config, context settings,
/// and session info into a single scrollable sheet.
///
/// Sections:
///   1. Header - title, workspace badge, model badge, agent badge
///   2. Trust Level - segmented button (from SessionConfigSheet)
///   3. Context - working directory and CLAUDE.md status (from ContextSettingsSheet)
///   4. Session Info - ID, model, tokens, prompt source (from SessionInfoSheet)
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
  late String _trustLevel;
  bool _isSaving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _trustLevel = TrustLevel.fromString(widget.session.trustLevel).name;
  }

  Future<void> _saveTrustLevel() async {
    if (_trustLevel == TrustLevel.fromString(widget.session.trustLevel).name) return;
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.patch(
        Uri.parse('$serverUrl/api/chat/${widget.session.id}/config'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
        },
        body: json.encode({'trustLevel': _trustLevel}),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          widget.onConfigSaved?.call();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Trust level updated'),
              backgroundColor: BrandColors.forest,
              duration: const Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else {
          setState(() => _saveError = 'Save failed (${response.statusCode})');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = widget.session;
    final metadata = widget.promptMetadata;
    final claudeMdPath = metadata?.workingDirectoryClaudeMd;

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

                  // --- Section 2: Trust Level ---
                  _buildTrustSection(isDark),

                  const SizedBox(height: Spacing.lg),
                  _divider(isDark),
                  const SizedBox(height: Spacing.lg),

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

  // ---- Trust Level Section ----

  Widget _buildTrustSection(bool isDark) {
    const levels = ['trusted', 'untrusted'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(isDark, 'Trust Level'),
        const SizedBox(height: Spacing.sm),
        SegmentedButton<String>(
          segments: levels.map((level) {
            final tl = TrustLevel.fromString(level);
            return ButtonSegment(
              value: level,
              label: Text(
                tl.displayName,
                style: const TextStyle(fontSize: TypographyTokens.labelSmall),
              ),
            );
          }).toList(),
          selected: {_trustLevel},
          onSelectionChanged: (selected) {
            setState(() => _trustLevel = selected.first);
            _saveTrustLevel();
          },
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return _trustColor(_trustLevel).withValues(alpha: 0.15);
              }
              return null;
            }),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          TrustLevel.fromString(_trustLevel).description,
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color:
                isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        if (_isSaving)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
          ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              _saveError!,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: BrandColors.error,
              ),
            ),
          ),
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

  Color _trustColor(String level) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TrustLevel.fromString(level).iconColor(isDark);
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
