import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/chat/models/workspace.dart';
import 'package:parachute/features/chat/providers/workspace_providers.dart';
import 'package:parachute/features/chat/widgets/workspace_dialog.dart';
import 'package:parachute/features/settings/models/trust_level.dart';

/// Workspace management section in Settings.
///
/// Lists workspaces with edit/delete actions and a create button.
class WorkspaceManagementSection extends ConsumerWidget {
  const WorkspaceManagementSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final workspacesAsync = ref.watch(workspacesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.workspaces_outline,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Workspaces',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showCreateDialog(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New'),
            ),
          ],
        ),
        SizedBox(height: Spacing.xs),
        Text(
          'Named capability sets that control what tools and permissions are available.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.md),

        // Workspace list
        workspacesAsync.when(
          data: (workspaces) {
            if (workspaces.isEmpty) {
              return Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.lg),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.workspaces_outline,
                        size: 40,
                        color: isDark
                            ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                            : BrandColors.stone.withValues(alpha: 0.4),
                      ),
                      SizedBox(height: Spacing.sm),
                      Text(
                        'No workspaces yet',
                        style: TextStyle(
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                        ),
                      ),
                      SizedBox(height: Spacing.xs),
                      Text(
                        'Create a workspace to organize sessions with shared settings',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark
                              ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                              : BrandColors.stone.withValues(alpha: 0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: workspaces
                  .map((ws) => _WorkspaceTile(workspace: ws, isDark: isDark))
                  .toList(),
            );
          },
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (error, _) => Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Text(
              'Failed to load workspaces: $error',
              style: TextStyle(color: BrandColors.error),
            ),
          ),
        ),
      ],
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    CreateWorkspaceDialog.show(
      context,
      onCreated: (_) => ref.invalidate(workspacesProvider),
    );
  }
}

/// Individual workspace tile with edit/delete actions.
class _WorkspaceTile extends ConsumerWidget {
  final Workspace workspace;
  final bool isDark;

  const _WorkspaceTile({required this.workspace, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: EdgeInsets.only(bottom: Spacing.sm),
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : Colors.white,
        borderRadius: Radii.card,
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
              : BrandColors.stone.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          // Trust level icon
          Icon(
            _trustIcon(workspace.trustLevel),
            size: 20,
            color: _trustColor(workspace.trustLevel),
          ),
          SizedBox(width: Spacing.md),
          // Workspace info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                SizedBox(height: 2),
                Row(
                  children: [
                    _Badge(
                      label: workspace.trustLevel,
                      color: _trustColor(workspace.trustLevel),
                      isDark: isDark,
                    ),
                    if (workspace.model != null) ...[
                      SizedBox(width: Spacing.xs),
                      _Badge(
                        label: workspace.model!,
                        color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                        isDark: isDark,
                      ),
                    ],
                  ],
                ),
                if (workspace.description.isNotEmpty) ...[
                  SizedBox(height: 4),
                  Text(
                    workspace.description,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // Actions
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              size: 20,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
            onSelected: (value) {
              if (value == 'edit') {
                _showEditDialog(context, ref);
              } else if (value == 'delete') {
                _confirmDelete(context, ref);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: BrandColors.error)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _trustIcon(String trust) {
    final tl = TrustLevel.fromString(trust);
    return tl.icon;
  }

  Color _trustColor(String trust) {
    final tl = TrustLevel.fromString(trust);
    return tl.iconColor(isDark);
  }

  void _showEditDialog(BuildContext context, WidgetRef ref) {
    EditWorkspaceDialog.show(
      context,
      workspace,
      onSaved: () => ref.invalidate(workspacesProvider),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDeleteWorkspace(context, workspace);
    if (!confirmed) return;
    try {
      final service = ref.read(workspaceServiceProvider);
      await service.deleteWorkspace(workspace.slug);
      ref.invalidate(workspacesProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }
}

/// Small colored badge widget.
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final bool isDark;

  const _Badge({required this.label, required this.color, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: TypographyTokens.labelSmall,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

