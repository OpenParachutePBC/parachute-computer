import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../chat/models/agent_info.dart';
import '../../chat/models/mcp_server_info.dart';
import '../../chat/models/plugin_info.dart';
import '../../chat/providers/mcp_providers.dart';
import '../../chat/providers/plugin_providers.dart';
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

          // Contents
          if (plugin.skills.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Skills',
                icon: Icons.bolt_outlined,
                items: plugin.skills,
                isDark: isDark,
              ),
            ),
          ],
          if (plugin.agents.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Agents',
                icon: Icons.smart_toy_outlined,
                items: plugin.agents,
                isDark: isDark,
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

class AgentDetailScreen extends StatelessWidget {
  final AgentInfo agent;
  const AgentDetailScreen({super.key, required this.agent});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
          _DetailSection(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      agent.isBuiltin ? Icons.chat_bubble_outline : Icons.smart_toy_outlined,
                      size: 24,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        agent.displayName,
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
                    _DetailChip(label: agent.source, isDark: isDark),
                    _DetailChip(label: agent.type, isDark: isDark),
                    if (agent.model != null)
                      _DetailChip(label: agent.model!, isDark: isDark),
                  ],
                ),
                if (agent.description != null && agent.description!.isNotEmpty) ...[
                  SizedBox(height: Spacing.md),
                  Text(
                    agent.description!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (agent.tools.isNotEmpty) ...[
            SizedBox(height: Spacing.md),
            _DetailSection(
              isDark: isDark,
              child: _ContentList(
                title: 'Tools',
                icon: Icons.build_outlined,
                items: agent.tools,
                isDark: isDark,
              ),
            ),
          ],
        ],
      ),
    );
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
