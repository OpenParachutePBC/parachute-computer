import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../chat/models/agent_info.dart';
import '../../chat/models/mcp_server_info.dart';
import '../../chat/models/plugin_info.dart';
import '../../chat/models/skill_info.dart';
import '../../chat/providers/agent_providers.dart';
import '../../chat/providers/mcp_providers.dart';
import '../../chat/providers/plugin_providers.dart';
import '../../chat/providers/skill_providers.dart';
import '../../chat/providers/chat_session_providers.dart';
import '../../chat/services/chat_service.dart';

// ============================================================
// Plugin Detail
// ============================================================

class PluginDetailScreen extends ConsumerWidget {
  final PluginInfo plugin;
  const PluginDetailScreen({super.key, required this.plugin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          plugin.displayName,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: ListView(
        padding: EdgeInsets.all(Spacing.lg),
        children: [
          // Header
          _DetailSection(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.extension_outlined,
                      size: 24,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        plugin.displayName,
                        style: TextStyle(
                          fontSize: TypographyTokens.headlineMedium,
                          fontWeight: FontWeight.w700,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    _DetailChip(label: 'v${plugin.version}', isDark: isDark),
                    _DetailChip(label: plugin.source, isDark: isDark),
                    if (plugin.author != null)
                      _DetailChip(label: 'by ${plugin.author}', isDark: isDark),
                  ],
                ),
                if (plugin.description.isNotEmpty) ...[
                  SizedBox(height: Spacing.md),
                  Text(
                    plugin.description,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Source URL
          if (plugin.sourceUrl != null) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: Row(
                children: [
                  Icon(
                    Icons.link,
                    size: 18,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      plugin.sourceUrl!,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        fontFamily: 'monospace',
                        color: isDark ? BrandColors.nightForest : BrandColors.forest,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: plugin.sourceUrl!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('URL copied')),
                      );
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    iconSize: 16,
                  ),
                ],
              ),
            ),
          ],

          // Tappable content lists
          if (plugin.skills.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _TappableContentList(
                title: 'Skills',
                icon: Icons.bolt_outlined,
                items: plugin.skills,
                isDark: isDark,
                onItemTap: (name) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SkillDetailScreen(
                      skill: SkillInfo(name: name),
                      pluginSlug: plugin.slug,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (plugin.agents.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _TappableContentList(
                title: 'Agents',
                icon: Icons.smart_toy_outlined,
                items: plugin.agents,
                isDark: isDark,
                onItemTap: (name) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AgentDetailScreen(
                      agent: AgentInfo(name: name, source: 'plugin'),
                      pluginSlug: plugin.slug,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (plugin.mcpNames.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'MCP Servers',
                icon: Icons.dns_outlined,
                items: plugin.mcpNames,
                isDark: isDark,
              ),
            ),
          ],

          // Actions
          SizedBox(height: Spacing.lg),
          if (plugin.isRemote)
            _ActionButton(
              label: 'Update Plugin',
              icon: Icons.refresh,
              isDark: isDark,
              onTap: () => _updatePlugin(context, ref),
            ),
          if (!plugin.isUserPlugin) ...[
            SizedBox(height: Spacing.sm),
            _ActionButton(
              label: 'Uninstall Plugin',
              icon: Icons.delete_outline,
              isDark: isDark,
              isDestructive: true,
              onTap: () => _uninstallPlugin(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _updatePlugin(BuildContext context, WidgetRef ref) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Updating...')),
    );
    try {
      final service = ref.read(chatServiceProvider);
      await service.updatePlugin(plugin.slug);
      ref.invalidate(pluginsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Plugin updated')));
      Navigator.pop(context);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _uninstallPlugin(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uninstall Plugin'),
        content: Text('Uninstall "${plugin.displayName}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Uninstall', style: TextStyle(color: BrandColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final service = ref.read(chatServiceProvider);
      await service.uninstallPlugin(plugin.slug);
      ref.invalidate(pluginsProvider);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to uninstall: $e')),
        );
      }
    }
  }
}

// ============================================================
// Agent Detail
// ============================================================

class AgentDetailScreen extends ConsumerWidget {
  final AgentInfo agent;
  final String? pluginSlug;
  const AgentDetailScreen({super.key, required this.agent, this.pluginSlug});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Fetch full detail
    final AsyncValue<AgentInfo> detailAsync;
    if (pluginSlug != null) {
      detailAsync = ref.watch(pluginAgentDetailProvider('$pluginSlug:${agent.name}'));
    } else {
      detailAsync = ref.watch(agentDetailProvider(agent.name));
    }

    // Use detail data when available, fall back to navigation param
    final detail = detailAsync.valueOrNull ?? agent;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          agent.displayName,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: ListView(
        padding: EdgeInsets.all(Spacing.lg),
        children: [
          // Header
          _DetailSection(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      detail.isBuiltin ? Icons.chat_bubble_outline : Icons.smart_toy_outlined,
                      size: 24,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        detail.displayName,
                        style: TextStyle(
                          fontSize: TypographyTokens.headlineMedium,
                          fontWeight: FontWeight.w700,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    _DetailChip(label: detail.source, isDark: isDark),
                    _DetailChip(label: detail.type, isDark: isDark),
                    if (detail.model != null)
                      _DetailChip(label: detail.model!, isDark: isDark),
                  ],
                ),
                if (detail.description != null && detail.description!.isNotEmpty) ...[
                  SizedBox(height: Spacing.md),
                  Text(
                    detail.description!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Tools
          if (detail.tools.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Tools',
                icon: Icons.build_outlined,
                items: detail.tools,
                isDark: isDark,
              ),
            ),
          ],

          // System prompt
          if (detail.systemPrompt != null && detail.systemPrompt!.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _CollapsiblePromptSection(
              title: 'System Prompt',
              content: detail.systemPrompt!,
              isDark: isDark,
            ),
          ],

          // Permissions
          if (detail.permissions != null) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _PermissionsSection(
                permissions: detail.permissions!,
                isDark: isDark,
              ),
            ),
          ],

          // MCP Servers
          if (detail.mcpServers != null) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _McpServersListSection(
                mcpServers: detail.mcpServers,
                isDark: isDark,
              ),
            ),
          ],

          // Spawns
          if (detail.spawns != null && detail.spawns!.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Spawns',
                icon: Icons.account_tree_outlined,
                items: detail.spawns!,
                isDark: isDark,
              ),
            ),
          ],

          // Constraints
          if (detail.constraints != null) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ConstraintsSection(
                constraints: detail.constraints!,
                isDark: isDark,
              ),
            ),
          ],

          // Loading indicator for detail fetch
          if (detailAsync.isLoading) ...[
            SizedBox(height: Spacing.md),
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// Skill Detail
// ============================================================

class SkillDetailScreen extends ConsumerWidget {
  final SkillInfo skill;
  final String? pluginSlug;
  const SkillDetailScreen({super.key, required this.skill, this.pluginSlug});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Fetch full detail
    final AsyncValue<SkillInfo> detailAsync;
    if (pluginSlug != null) {
      detailAsync = ref.watch(pluginSkillDetailProvider('$pluginSlug:${skill.name}'));
    } else {
      detailAsync = ref.watch(skillDetailProvider(skill.name));
    }

    final detail = detailAsync.valueOrNull ?? skill;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          detail.name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: ListView(
        padding: EdgeInsets.all(Spacing.lg),
        children: [
          // Header
          _DetailSection(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.bolt_outlined,
                      size: 24,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        detail.name,
                        style: TextStyle(
                          fontSize: TypographyTokens.headlineMedium,
                          fontWeight: FontWeight.w700,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    if (detail.version != null)
                      _DetailChip(label: 'v${detail.version}', isDark: isDark),
                    if (detail.isDirectory)
                      _DetailChip(label: 'directory', isDark: isDark),
                    if (detail.source != null)
                      _DetailChip(label: detail.source!, isDark: isDark),
                  ],
                ),
                if (detail.description.isNotEmpty) ...[
                  SizedBox(height: Spacing.md),
                  Text(
                    detail.description,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Allowed tools
          if (detail.allowedTools.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Allowed Tools',
                icon: Icons.build_outlined,
                items: detail.allowedTools,
                isDark: isDark,
              ),
            ),
          ],

          // Content (collapsible)
          if (detail.content != null && detail.content!.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _CollapsiblePromptSection(
              title: 'Content',
              content: detail.content!,
              isDark: isDark,
            ),
          ],

          // Files (for directory skills)
          if (detail.files.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _SkillFilesSection(
                files: detail.files,
                isDark: isDark,
              ),
            ),
          ],

          // Loading indicator
          if (detailAsync.isLoading) ...[
            SizedBox(height: Spacing.md),
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ],

          // Delete action (custom skills only, not plugin)
          if (pluginSlug == null && detail.source != 'plugin') ...[
            SizedBox(height: Spacing.lg),
            _ActionButton(
              label: 'Delete Skill',
              icon: Icons.delete_outline,
              isDark: isDark,
              isDestructive: true,
              onTap: () => _deleteSkill(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteSkill(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill'),
        content: Text('Delete "${skill.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: BrandColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final service = ref.read(chatServiceProvider);
      await service.deleteSkill(skill.name);
      ref.invalidate(skillsProvider);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

// ============================================================
// MCP Detail
// ============================================================

class McpDetailScreen extends ConsumerWidget {
  final McpServerInfo server;
  const McpDetailScreen({super.key, required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasErrors = server.validationErrors != null && server.validationErrors!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          server.name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: ListView(
        padding: EdgeInsets.all(Spacing.lg),
        children: [
          _DetailSection(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 24,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        server.name,
                        style: TextStyle(
                          fontSize: TypographyTokens.headlineMedium,
                          fontWeight: FontWeight.w700,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: [
                    _DetailChip(label: server.displayType, isDark: isDark),
                    if (server.builtin)
                      _DetailChip(label: 'builtin', isDark: isDark),
                  ],
                ),
                if (server.displayCommand.isNotEmpty) ...[
                  SizedBox(height: Spacing.md),
                  Text(
                    server.displayCommand,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontFamily: 'monospace',
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
                if (hasErrors) ...[
                  SizedBox(height: Spacing.md),
                  for (final error in server.validationErrors!)
                    Padding(
                      padding: EdgeInsets.only(bottom: Spacing.xs),
                      child: Text(
                        error,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: BrandColors.error,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),

          // Tools section
          SizedBox(height: Spacing.md),
          _McpToolsSection(serverName: server.name, isDark: isDark),

          SizedBox(height: Spacing.lg),
          _ActionButton(
            label: 'Test Connection',
            icon: Icons.play_arrow_outlined,
            isDark: isDark,
            onTap: () => _testMcp(context, ref),
          ),
          if (!server.builtin) ...[
            SizedBox(height: Spacing.sm),
            _ActionButton(
              label: 'Delete MCP Server',
              icon: Icons.delete_outline,
              isDark: isDark,
              isDestructive: true,
              onTap: () => _deleteMcp(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _testMcp(BuildContext context, WidgetRef ref) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Testing "${server.name}"...')),
    );
    try {
      final service = ref.read(chatServiceProvider);
      final result = await service.testMcpServer(server.name);
      if (!context.mounted) return;
      final status = result['status'] ?? 'unknown';
      final msg = status == 'ok' || status == 'connected'
          ? 'Connected to "${server.name}"'
          : 'Test result: $status';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Test failed: $e')));
    }
  }

  Future<void> _deleteMcp(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete MCP Server'),
        content: Text('Remove "${server.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: BrandColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final service = ref.read(chatServiceProvider);
      await service.deleteMcpServer(server.name);
      ref.invalidate(mcpServersProvider);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

// ============================================================
// MCP Tools Section (async)
// ============================================================

class _McpToolsSection extends ConsumerWidget {
  final String serverName;
  final bool isDark;
  const _McpToolsSection({required this.serverName, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toolsAsync = ref.watch(mcpToolsProvider(serverName));

    return _DetailSection(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 18,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest),
              SizedBox(width: Spacing.xs),
              Text(
                'Tools',
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          toolsAsync.when(
            loading: () => Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: Spacing.sm),
                Text(
                  'Discovering tools...',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    fontStyle: FontStyle.italic,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
            error: (e, _) => Row(
              children: [
                Icon(Icons.warning_amber_outlined, size: 16, color: BrandColors.error),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    'Could not discover tools',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: BrandColors.error,
                    ),
                  ),
                ),
              ],
            ),
            data: (tools) => tools.isEmpty
                ? Text(
                    'No tools discovered',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontStyle: FontStyle.italic,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${tools.length} tools',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                      SizedBox(height: Spacing.xs),
                      for (final tool in tools) ...[
                        Padding(
                          padding: EdgeInsets.only(bottom: Spacing.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tool.name,
                                style: TextStyle(
                                  fontSize: TypographyTokens.bodySmall,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'monospace',
                                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                                ),
                              ),
                              if (tool.description != null && tool.description!.isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(top: 2),
                                  child: Text(
                                    tool.description!,
                                    style: TextStyle(
                                      fontSize: TypographyTokens.labelSmall,
                                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Collapsible Prompt Section
// ============================================================

class _CollapsiblePromptSection extends StatefulWidget {
  final String title;
  final String content;
  final bool isDark;
  const _CollapsiblePromptSection({
    required this.title,
    required this.content,
    required this.isDark,
  });

  @override
  State<_CollapsiblePromptSection> createState() => _CollapsiblePromptSectionState();
}

class _CollapsiblePromptSectionState extends State<_CollapsiblePromptSection> {
  late bool _collapsed;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.content.length > 200;
  }

  @override
  Widget build(BuildContext context) {
    return _DetailSection(
      isDark: widget.isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined, size: 18,
                  color: widget.isDark ? BrandColors.nightForest : BrandColors.forest),
              SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    fontWeight: FontWeight.w600,
                    color: widget.isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 16,
              ),
              SizedBox(width: Spacing.xs),
              GestureDetector(
                onTap: () => setState(() => _collapsed = !_collapsed),
                child: Icon(
                  _collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          AnimatedCrossFade(
            firstChild: Text(
              widget.content.length > 200
                  ? '${widget.content.substring(0, 200)}...'
                  : widget.content,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontFamily: 'monospace',
                color: widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            secondChild: Text(
              widget.content,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontFamily: 'monospace',
                color: widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            crossFadeState: _collapsed
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Agent-specific sections
// ============================================================

class _PermissionsSection extends StatelessWidget {
  final Map<String, dynamic> permissions;
  final bool isDark;
  const _PermissionsSection({required this.permissions, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.security_outlined, size: 18,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              'Permissions',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        for (final entry in permissions.entries)
          if (entry.value is List && (entry.value as List).isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: Spacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 80,
                    child: Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: Spacing.xs,
                      runSpacing: Spacing.xs,
                      children: (entry.value as List)
                          .map((v) => _DetailChip(label: v.toString(), isDark: isDark))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

class _ConstraintsSection extends StatelessWidget {
  final Map<String, dynamic> constraints;
  final bool isDark;
  const _ConstraintsSection({required this.constraints, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune_outlined, size: 18,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              'Constraints',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: constraints.entries.map((e) {
            final label = switch (e.key) {
              'maxSpawns' => 'Max spawns: ${e.value}',
              'timeout' => 'Timeout: ${e.value}s',
              _ => '${e.key}: ${e.value}',
            };
            return _DetailChip(label: label, isDark: isDark);
          }).toList(),
        ),
      ],
    );
  }
}

class _McpServersListSection extends StatelessWidget {
  final dynamic mcpServers;
  final bool isDark;
  const _McpServersListSection({required this.mcpServers, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 18,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              'MCP Servers',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        if (mcpServers == 'all')
          _DetailChip(label: 'all (unrestricted)', isDark: isDark)
        else if (mcpServers is List)
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: (mcpServers as List)
                .map((s) => _DetailChip(label: s.toString(), isDark: isDark))
                .toList(),
          )
        else
          Text(
            'None',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontStyle: FontStyle.italic,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
      ],
    );
  }
}

// ============================================================
// Skill-specific sections
// ============================================================

class _SkillFilesSection extends StatelessWidget {
  final List<SkillFile> files;
  final bool isDark;
  const _SkillFilesSection({required this.files, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.folder_outlined, size: 18,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              'Files (${files.length})',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        for (final file in files)
          Padding(
            padding: EdgeInsets.only(bottom: Spacing.xs),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: 14,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    file.name,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontFamily: 'monospace',
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
                Text(
                  file.humanSize,
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ============================================================
// Shared Detail Widgets
// ============================================================

class _DetailSection extends StatelessWidget {
  final bool isDark;
  final Widget child;
  const _DetailSection({required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: child,
    );
  }
}

class _DetailChip extends StatelessWidget {
  final String label;
  final bool isDark;
  const _DetailChip({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.15)
            : BrandColors.forestMist,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: TypographyTokens.labelSmall,
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
        ),
      ),
    );
  }
}

class _ContentList extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> items;
  final bool isDark;
  const _ContentList({
    required this.title,
    required this.icon,
    required this.items,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              '$title (${items.length})',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: items.map((item) => _DetailChip(label: item, isDark: isDark)).toList(),
        ),
      ],
    );
  }
}

class _TappableContentList extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> items;
  final bool isDark;
  final void Function(String name) onItemTap;
  const _TappableContentList({
    required this.title,
    required this.icon,
    required this.items,
    required this.isDark,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.xs),
            Text(
              '$title (${items.length})',
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: items.map((item) => GestureDetector(
            onTap: () => onItemTap(item),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightForest.withValues(alpha: 0.15)
                    : BrandColors.forestMist,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item,
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ],
              ),
            ),
          )).toList(),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isDark;
  final bool isDestructive;
  final VoidCallback onTap;
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.isDark,
    this.isDestructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive
        ? BrandColors.error
        : isDark
            ? BrandColors.nightForest
            : BrandColors.forest;

    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: color),
      label: Text(label, style: TextStyle(color: color)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        padding: EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.md),
      ),
    );
  }
}
