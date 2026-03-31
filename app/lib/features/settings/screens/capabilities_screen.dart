import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../chat/providers/agent_providers.dart';
import '../../chat/providers/skill_providers.dart';
import '../../chat/providers/mcp_providers.dart';
import '../../chat/providers/plugin_providers.dart';
import '../../chat/providers/chat_session_providers.dart';
import '../../chat/services/chat_service.dart';
import '../../chat/models/agent_info.dart';
import '../../chat/models/skill_info.dart';
import '../../chat/models/mcp_server_info.dart';
import '../../chat/models/plugin_info.dart';
import 'capability_detail_screen.dart';

/// Browse and manage agents, skills, and MCP servers.
class CapabilitiesScreen extends ConsumerStatefulWidget {
  const CapabilitiesScreen({super.key});

  @override
  ConsumerState<CapabilitiesScreen> createState() => _CapabilitiesScreenState();
}

class _CapabilitiesScreenState extends ConsumerState<CapabilitiesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Capabilities',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor:
            isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: isDark ? BrandColors.nightForest : BrandColors.forest,
          unselectedLabelColor:
              isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          indicatorColor:
              isDark ? BrandColors.nightForest : BrandColors.forest,
          tabs: const [
            Tab(text: 'Agents'),
            Tab(text: 'Skills'),
            Tab(text: 'MCPs'),
            Tab(text: 'Plugins'),
          ],
        ),
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: TabBarView(
        controller: _tabController,
        children: [
          _AgentsTab(isDark: isDark),
          _SkillsTab(isDark: isDark),
          _McpServersTab(isDark: isDark),
          _PluginsTab(isDark: isDark),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _onFabPressed(context),
        icon: const Icon(Icons.add),
        label: Text(_fabLabel),
        backgroundColor:
            isDark ? BrandColors.nightForest : BrandColors.forest,
        foregroundColor: Colors.white,
      ),
    );
  }

  String get _fabLabel {
    switch (_tabController.index) {
      case 0:
        return 'Add Agent';
      case 1:
        return 'Add Skill';
      case 2:
        return 'Add MCP';
      case 3:
        return 'Install Plugin';
      default:
        return 'Add';
    }
  }

  void _onFabPressed(BuildContext context) {
    switch (_tabController.index) {
      case 0:
        _showCreateAgentDialog(context);
        break;
      case 1:
        _showCreateSkillDialog(context);
        break;
      case 2:
        _showAddMcpDialog(context);
        break;
      case 3:
        _showInstallPluginDialog(context);
        break;
    }
  }

  void _showCreateAgentDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateAgentDialog(
        onCreated: () => ref.invalidate(agentsProvider),
        ref: ref,
      ),
    );
  }

  void _showCreateSkillDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CreateSkillDialog(
        onCreated: () => ref.invalidate(skillsProvider),
        ref: ref,
      ),
    );
  }

  void _showAddMcpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _AddMcpDialog(
        onCreated: () => ref.invalidate(mcpServersProvider),
        ref: ref,
      ),
    );
  }

  void _showInstallPluginDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _InstallPluginDialog(
        onInstalled: () => ref.invalidate(pluginsProvider),
        ref: ref,
      ),
    );
  }
}

// ============================================================
// Agents Tab
// ============================================================

class _AgentsTab extends ConsumerWidget {
  final bool isDark;
  const _AgentsTab({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentsProvider);

    return agents.when(
      data: (list) => list.isEmpty
          ? _EmptyState(
              isDark: isDark,
              message: 'No agents found',
              actionLabel: 'Add your first agent',
              onAction: () => showDialog(
                context: context,
                builder: (_) => _CreateAgentDialog(
                  onCreated: () => ref.invalidate(agentsProvider),
                  ref: ref,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(agentsProvider),
              child: ListView.separated(
                padding: EdgeInsets.all(Spacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
                itemBuilder: (_, i) => _AgentCard(
                  agent: list[i],
                  isDark: isDark,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AgentDetailScreen(agent: list[i]),
                    ),
                  ),
                  onDelete: list[i].source == 'sdk'
                      ? () => _deleteAgent(context, ref, list[i].name)
                      : null,
                ),
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(
        isDark: isDark,
        message: 'Could not load agents',
        onRetry: () => ref.invalidate(agentsProvider),
      ),
    );
  }

  Future<void> _deleteAgent(
      BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Agent'),
        content: Text('Delete agent "$name"? This cannot be undone.'),
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
      await service.deleteAgent(name);
      ref.invalidate(agentsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted agent "$name"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

class _AgentCard extends StatelessWidget {
  final AgentInfo agent;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const _AgentCard({required this.agent, required this.isDark, this.onTap, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _iconForSource(agent.source),
                size: 20,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  agent.displayName,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              _SourceBadge(source: agent.source, isDark: isDark),
              if (onDelete != null) ...[
                SizedBox(width: Spacing.xs),
                _CardMenuButton(
                  isDark: isDark,
                  actions: [
                    _MenuAction('Delete', Icons.delete_outline, onDelete!),
                  ],
                ),
              ],
            ],
          ),
          if (agent.description != null &&
              agent.description!.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              agent.description!,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (agent.model != null || agent.tools.isNotEmpty) ...[
            SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                if (agent.model != null)
                  _InfoChip(
                    label: agent.model!,
                    isDark: isDark,
                  ),
                if (agent.tools.isNotEmpty)
                  _InfoChip(
                    label: '${agent.tools.length} tools',
                    isDark: isDark,
                  ),
              ],
            ),
          ],
        ],
      ),
      ),
    );
  }

  IconData _iconForSource(String source) {
    switch (source) {
      case 'builtin':
        return Icons.chat_bubble_outline;
      case 'sdk':
        return Icons.smart_toy_outlined;
      default:
        return Icons.extension_outlined;
    }
  }
}

// ============================================================
// Skills Tab
// ============================================================

class _SkillsTab extends ConsumerWidget {
  final bool isDark;
  const _SkillsTab({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skills = ref.watch(skillsProvider);

    return skills.when(
      data: (list) => list.isEmpty
          ? _EmptyState(
              isDark: isDark,
              message: 'No skills found',
              actionLabel: 'Add your first skill',
              onAction: () => showDialog(
                context: context,
                builder: (_) => _CreateSkillDialog(
                  onCreated: () => ref.invalidate(skillsProvider),
                  ref: ref,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(skillsProvider),
              child: ListView.separated(
                padding: EdgeInsets.all(Spacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
                itemBuilder: (_, i) => _SkillCard(
                  skill: list[i],
                  isDark: isDark,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SkillDetailScreen(skill: list[i]),
                    ),
                  ),
                  onDelete: () => _deleteSkill(context, ref, list[i].name),
                ),
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(
        isDark: isDark,
        message: 'Could not load skills',
        onRetry: () => ref.invalidate(skillsProvider),
      ),
    );
  }

  Future<void> _deleteSkill(
      BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill'),
        content: Text('Delete skill "$name"? This cannot be undone.'),
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
      await service.deleteSkill(name);
      ref.invalidate(skillsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted skill "$name"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

class _SkillCard extends StatelessWidget {
  final SkillInfo skill;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const _SkillCard({required this.skill, required this.isDark, this.onTap, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bolt_outlined,
                size: 20,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  skill.name,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyLarge,
                    fontWeight: FontWeight.w600,
                    color:
                        isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              if (onDelete != null)
                _CardMenuButton(
                  isDark: isDark,
                  actions: [
                    _MenuAction('Delete', Icons.delete_outline, onDelete!),
                  ],
                ),
            ],
          ),
          if (skill.description.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              skill.description,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      ),
    );
  }
}

// ============================================================
// MCP Servers Tab
// ============================================================

class _McpServersTab extends ConsumerWidget {
  final bool isDark;
  const _McpServersTab({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mcps = ref.watch(mcpServersProvider);

    return mcps.when(
      data: (list) => list.isEmpty
          ? _EmptyState(
              isDark: isDark,
              message: 'No MCP servers configured',
              actionLabel: 'Add your first MCP server',
              onAction: () => showDialog(
                context: context,
                builder: (_) => _AddMcpDialog(
                  onCreated: () => ref.invalidate(mcpServersProvider),
                  ref: ref,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(mcpServersProvider),
              child: ListView.separated(
                padding: EdgeInsets.all(Spacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
                itemBuilder: (_, i) => _McpServerCard(
                  server: list[i],
                  isDark: isDark,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => McpDetailScreen(server: list[i]),
                    ),
                  ),
                  onTest: () => _testMcp(context, ref, list[i].name),
                  onDelete: list[i].builtin
                      ? null
                      : () => _deleteMcp(context, ref, list[i].name),
                ),
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(
        isDark: isDark,
        message: 'Could not load MCP servers',
        onRetry: () => ref.invalidate(mcpServersProvider),
      ),
    );
  }

  Future<void> _testMcp(
      BuildContext context, WidgetRef ref, String name) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Testing "$name"...')),
    );
    try {
      final service = ref.read(chatServiceProvider);
      final result = await service.testMcpServer(name);
      if (!context.mounted) return;
      final status = result['status'] ?? 'unknown';
      final tools = result['tools_count'] ?? result['tools'];
      final msg = status == 'ok' || status == 'connected'
          ? 'Connected to "$name"${tools != null ? ' ($tools tools)' : ''}'
          : 'Test result: $status';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Test failed: $e')),
        );
    }
  }

  Future<void> _deleteMcp(
      BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete MCP Server'),
        content: Text('Remove MCP server "$name"?'),
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
      await service.deleteMcpServer(name);
      ref.invalidate(mcpServersProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed MCP server "$name"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

class _McpServerCard extends StatelessWidget {
  final McpServerInfo server;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onTest;
  final VoidCallback? onDelete;
  const _McpServerCard({
    required this.server,
    required this.isDark,
    this.onTap,
    this.onTest,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasErrors =
        server.validationErrors != null && server.validationErrors!.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: hasErrors
              ? BrandColors.error.withValues(alpha: 0.4)
              : isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.dns_outlined,
                size: 20,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  server.name,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyLarge,
                    fontWeight: FontWeight.w600,
                    color:
                        isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              _InfoChip(label: server.displayType, isDark: isDark),
              if (server.builtin) ...[
                SizedBox(width: Spacing.xs),
                _InfoChip(label: 'builtin', isDark: isDark),
              ],
              if (onTest != null || onDelete != null) ...[
                SizedBox(width: Spacing.xs),
                _CardMenuButton(
                  isDark: isDark,
                  actions: [
                    if (onTest != null)
                      _MenuAction('Test Connection', Icons.play_arrow_outlined, onTest!),
                    if (onDelete != null)
                      _MenuAction('Delete', Icons.delete_outline, onDelete!),
                  ],
                ),
              ],
            ],
          ),
          if (server.displayCommand.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              server.displayCommand,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontFamily: 'monospace',
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (hasErrors) ...[
            SizedBox(height: Spacing.xs),
            Text(
              server.validationErrors!.first,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: BrandColors.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      ),
    );
  }
}

// ============================================================
// Plugins Tab
// ============================================================

class _PluginsTab extends ConsumerWidget {
  final bool isDark;
  const _PluginsTab({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginsProvider);

    return plugins.when(
      data: (list) => list.isEmpty
          ? _EmptyState(
              isDark: isDark,
              message: 'No plugins installed',
              actionLabel: 'Install your first plugin',
              onAction: () => showDialog(
                context: context,
                builder: (_) => _InstallPluginDialog(
                  onInstalled: () => ref.invalidate(pluginsProvider),
                  ref: ref,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(pluginsProvider),
              child: ListView.separated(
                padding: EdgeInsets.all(Spacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
                itemBuilder: (_, i) => _PluginCard(
                  plugin: list[i],
                  isDark: isDark,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PluginDetailScreen(plugin: list[i]),
                    ),
                  ),
                  onUpdate: list[i].isRemote
                      ? () => _updatePlugin(context, ref, list[i].slug)
                      : null,
                  onDelete: !list[i].isUserPlugin
                      ? () => _deletePlugin(context, ref, list[i].slug)
                      : null,
                ),
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorState(
        isDark: isDark,
        message: 'Could not load plugins',
        onRetry: () => ref.invalidate(pluginsProvider),
      ),
    );
  }

  Future<void> _updatePlugin(
      BuildContext context, WidgetRef ref, String slug) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Updating "$slug"...')),
    );
    try {
      final service = ref.read(chatServiceProvider);
      await service.updatePlugin(slug);
      ref.invalidate(pluginsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Updated "$slug"')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _deletePlugin(
      BuildContext context, WidgetRef ref, String slug) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uninstall Plugin'),
        content: Text('Uninstall plugin "$slug"? This cannot be undone.'),
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
      await service.uninstallPlugin(slug);
      ref.invalidate(pluginsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uninstalled "$slug"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to uninstall: $e')),
        );
      }
    }
  }
}

class _PluginCard extends StatelessWidget {
  final PluginInfo plugin;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onUpdate;
  final VoidCallback? onDelete;
  const _PluginCard({
    required this.plugin,
    required this.isDark,
    this.onTap,
    this.onUpdate,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.extension_outlined,
                size: 20,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  plugin.displayName,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              _InfoChip(label: 'v${plugin.version}', isDark: isDark),
              SizedBox(width: Spacing.xs),
              _InfoChip(label: plugin.source, isDark: isDark),
              if (onUpdate != null || onDelete != null) ...[
                SizedBox(width: Spacing.xs),
                _CardMenuButton(
                  isDark: isDark,
                  actions: [
                    if (onUpdate != null)
                      _MenuAction('Update', Icons.refresh_outlined, onUpdate!),
                    if (onDelete != null)
                      _MenuAction('Uninstall', Icons.delete_outline, onDelete!),
                  ],
                ),
              ],
            ],
          ),
          if (plugin.description.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              plugin.description,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (plugin.capabilityCount > 0) ...[
            SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                if (plugin.skills.isNotEmpty)
                  _InfoChip(
                    label: '${plugin.skills.length} skills',
                    isDark: isDark,
                  ),
                if (plugin.agents.isNotEmpty)
                  _InfoChip(
                    label: '${plugin.agents.length} agents',
                    isDark: isDark,
                  ),
                if (plugin.mcpNames.isNotEmpty)
                  _InfoChip(
                    label: '${plugin.mcpNames.length} MCPs',
                    isDark: isDark,
                  ),
              ],
            ),
          ],
          if (plugin.author != null) ...[
            SizedBox(height: Spacing.xs),
            Text(
              'by ${plugin.author}',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

// ============================================================
// Create Dialogs
// ============================================================

class _CreateAgentDialog extends StatefulWidget {
  final VoidCallback onCreated;
  final WidgetRef ref;
  const _CreateAgentDialog({required this.onCreated, required this.ref});

  @override
  State<_CreateAgentDialog> createState() => _CreateAgentDialogState();
}

class _CreateAgentDialogState extends State<_CreateAgentDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _promptController = TextEditingController();
  String? _model;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Agent'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. code-reviewer',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What does this agent do?',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _promptController,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  hintText: 'System prompt for the agent...',
                  alignLabelWithHint: true,
                ),
                maxLines: 5,
                minLines: 3,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _model,
                decoration: const InputDecoration(labelText: 'Model (optional)'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Default')),
                  DropdownMenuItem(value: 'sonnet', child: Text('Sonnet')),
                  DropdownMenuItem(value: 'opus', child: Text('Opus')),
                  DropdownMenuItem(value: 'haiku', child: Text('Haiku')),
                ],
                onChanged: (val) => setState(() => _model = val),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  static final _agentNameRegex = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]*$');

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final prompt = _promptController.text.trim();
    if (name.isEmpty || prompt.isEmpty) return;

    if (!_agentNameRegex.hasMatch(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent name must contain only letters, numbers, hyphens, and underscores')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final service = widget.ref.read(chatServiceProvider);
      await service.createAgent(
        name: name,
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        prompt: prompt,
        model: _model,
      );
      widget.onCreated();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create agent: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _CreateSkillDialog extends StatefulWidget {
  final VoidCallback onCreated;
  final WidgetRef ref;
  const _CreateSkillDialog({required this.onCreated, required this.ref});

  @override
  State<_CreateSkillDialog> createState() => _CreateSkillDialogState();
}

class _CreateSkillDialogState extends State<_CreateSkillDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _contentController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Skill'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. summarize',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What does this skill do?',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                decoration: const InputDecoration(
                  labelText: 'Content',
                  hintText: 'Skill prompt template...',
                  alignLabelWithHint: true,
                ),
                maxLines: 5,
                minLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final content = _contentController.text.trim();
    if (name.isEmpty || content.isEmpty) return;

    setState(() => _saving = true);
    try {
      final service = widget.ref.read(chatServiceProvider);
      await service.createSkill(
        name: name,
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        content: content,
      );
      widget.onCreated();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create skill: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _AddMcpDialog extends StatefulWidget {
  final VoidCallback onCreated;
  final WidgetRef ref;
  const _AddMcpDialog({required this.onCreated, required this.ref});

  @override
  State<_AddMcpDialog> createState() => _AddMcpDialogState();
}

class _AddMcpDialogState extends State<_AddMcpDialog> {
  final _nameController = TextEditingController();
  final _commandController = TextEditingController();
  final _argsController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isHttp = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _argsController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add MCP Server'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. my-mcp-server',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('stdio')),
                  ButtonSegment(value: true, label: Text('HTTP/SSE')),
                ],
                selected: {_isHttp},
                onSelectionChanged: (val) =>
                    setState(() => _isHttp = val.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 12),
              if (_isHttp)
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'http://localhost:8080/sse',
                  ),
                )
              else ...[
                TextField(
                  controller: _commandController,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: 'e.g. npx, uvx, node',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _argsController,
                  decoration: const InputDecoration(
                    labelText: 'Arguments (space-separated)',
                    hintText: 'e.g. -y @modelcontextprotocol/server-github',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final Map<String, dynamic> config;
    if (_isHttp) {
      final url = _urlController.text.trim();
      if (url.isEmpty) return;
      config = {'url': url};
    } else {
      final command = _commandController.text.trim();
      if (command.isEmpty) return;
      final argsText = _argsController.text.trim();
      final args = argsText.isEmpty
          ? <String>[]
          : argsText.split(RegExp(r'\s+')).toList();
      config = {'command': command, 'args': args};
    }

    setState(() => _saving = true);
    try {
      final service = widget.ref.read(chatServiceProvider);
      await service.addMcpServer(name: name, config: config);
      widget.onCreated();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add MCP server: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _InstallPluginDialog extends StatefulWidget {
  final VoidCallback onInstalled;
  final WidgetRef ref;
  const _InstallPluginDialog({required this.onInstalled, required this.ref});

  @override
  State<_InstallPluginDialog> createState() => _InstallPluginDialogState();
}

class _InstallPluginDialogState extends State<_InstallPluginDialog> {
  final _urlController = TextEditingController();
  bool _installing = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Install Plugin'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Install a plugin from a GitHub URL. The repository should contain '
                'SDK-layout files (.claude/agents/, skills/, .mcp.json).',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'GitHub URL',
                  hintText: 'https://github.com/org/plugin-name',
                ),
                autofocus: true,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: BrandColors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _installing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _installing ? null : _install,
          child: _installing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Install'),
        ),
      ],
    );
  }

  Future<void> _install() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(() => _error = 'URL must start with https://');
      return;
    }

    setState(() {
      _installing = true;
      _error = null;
    });

    try {
      final service = widget.ref.read(chatServiceProvider);
      final plugin = await service.installPlugin(url: url);
      widget.onInstalled();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Installed "${plugin.displayName}"')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _installing = false;
        });
      }
    }
  }
}

// ============================================================
// Shared Widgets
// ============================================================

class _MenuAction {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _MenuAction(this.label, this.icon, this.onTap);
}

class _CardMenuButton extends StatelessWidget {
  final bool isDark;
  final List<_MenuAction> actions;
  const _CardMenuButton({required this.isDark, required this.actions});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      itemBuilder: (_) => [
        for (var i = 0; i < actions.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(actions[i].icon, size: 18),
                const SizedBox(width: 8),
                Text(actions[i].label),
              ],
            ),
          ),
      ],
      onSelected: (i) => actions[i].onTap(),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String source;
  final bool isDark;
  const _SourceBadge({required this.source, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final label = switch (source) {
      'builtin' => 'built-in',
      'sdk' => 'user',
      'vault_agents' => 'vault',
      'custom_agents' => 'custom',
      _ => source,
    };
    return _InfoChip(label: label, isDark: isDark);
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final bool isDark;
  const _InfoChip({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
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

class _EmptyState extends StatelessWidget {
  final bool isDark;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _EmptyState({
    required this.isDark,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: Spacing.md),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final bool isDark;
  final String message;
  final VoidCallback? onRetry;
  const _ErrorState({required this.isDark, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 32,
              color: BrandColors.error,
            ),
            SizedBox(height: Spacing.sm),
            Text(
              message,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              SizedBox(height: Spacing.md),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
