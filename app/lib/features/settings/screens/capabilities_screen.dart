import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../chat/providers/agent_providers.dart';
import '../../chat/providers/skill_providers.dart';
import '../../chat/providers/mcp_providers.dart';
import '../../chat/models/agent_info.dart';
import '../../chat/models/skill_info.dart';
import '../../chat/models/mcp_server_info.dart';

/// Browse available agents, skills, and MCP servers.
class CapabilitiesScreen extends ConsumerWidget {
  const CapabilitiesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
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
            labelColor: isDark ? BrandColors.nightForest : BrandColors.forest,
            unselectedLabelColor:
                isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            indicatorColor:
                isDark ? BrandColors.nightForest : BrandColors.forest,
            tabs: const [
              Tab(text: 'Agents'),
              Tab(text: 'Skills'),
              Tab(text: 'MCP Servers'),
            ],
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        body: TabBarView(
          children: [
            _AgentsTab(isDark: isDark),
            _SkillsTab(isDark: isDark),
            _McpServersTab(isDark: isDark),
          ],
        ),
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
          ? _EmptyState(isDark: isDark, message: 'No agents found')
          : ListView.separated(
              padding: EdgeInsets.all(Spacing.lg),
              itemCount: list.length,
              separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
              itemBuilder: (_, i) => _AgentCard(agent: list[i], isDark: isDark),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          _ErrorState(isDark: isDark, message: 'Could not load agents'),
    );
  }
}

class _AgentCard extends StatelessWidget {
  final AgentInfo agent;
  final bool isDark;
  const _AgentCard({required this.agent, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }

  IconData _iconForSource(String source) {
    switch (source) {
      case 'builtin':
        return Icons.chat_bubble_outline;
      case 'vault_agents':
        return Icons.auto_awesome;
      case 'custom_agents':
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
              message: 'No skills found. Add .md files to .skills/',
            )
          : ListView.separated(
              padding: EdgeInsets.all(Spacing.lg),
              itemCount: list.length,
              separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
              itemBuilder: (_, i) => _SkillCard(skill: list[i], isDark: isDark),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          _ErrorState(isDark: isDark, message: 'Could not load skills'),
    );
  }
}

class _SkillCard extends StatelessWidget {
  final SkillInfo skill;
  final bool isDark;
  const _SkillCard({required this.skill, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          ? _EmptyState(isDark: isDark, message: 'No MCP servers configured')
          : ListView.separated(
              padding: EdgeInsets.all(Spacing.lg),
              itemCount: list.length,
              separatorBuilder: (_, _) => SizedBox(height: Spacing.sm),
              itemBuilder: (_, i) =>
                  _McpServerCard(server: list[i], isDark: isDark),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          _ErrorState(isDark: isDark, message: 'Could not load MCP servers'),
    );
  }
}

class _McpServerCard extends StatelessWidget {
  final McpServerInfo server;
  final bool isDark;
  const _McpServerCard({required this.server, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final hasErrors =
        server.validationErrors != null && server.validationErrors!.isNotEmpty;

    return Container(
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
    );
  }
}

// ============================================================
// Shared Widgets
// ============================================================

class _SourceBadge extends StatelessWidget {
  final String source;
  final bool isDark;
  const _SourceBadge({required this.source, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final label = switch (source) {
      'builtin' => 'builtin',
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
  const _EmptyState({required this.isDark, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xxl),
        child: Text(
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
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final bool isDark;
  final String message;
  const _ErrorState({required this.isDark, required this.message});

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
          ],
        ),
      ),
    );
  }
}
