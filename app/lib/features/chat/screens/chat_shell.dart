import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/workspace.dart';
import '../../settings/models/trust_level.dart';
import '../providers/chat_layout_provider.dart';
import '../providers/workspace_providers.dart';
import '../widgets/session_list_panel.dart';
import '../widgets/chat_content_panel.dart';
import '../widgets/workspace_dialog.dart';

/// Adaptive shell for the chat feature.
///
/// Uses LayoutBuilder to pick the right layout:
/// - **Mobile** (<600px): Just SessionListPanel; tapping a session pushes ChatScreen.
/// - **Tablet** (600–1199px): Two-column — session list + chat content side by side.
/// - **Desktop** (≥1200px): Three-column — workspace sidebar + session list + chat content.
class ChatShell extends ConsumerWidget {
  const ChatShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mode = ChatLayoutBreakpoints.fromWidth(constraints.maxWidth);

        // Update the layout mode provider only when the mode actually changes
        // to avoid redundant invalidations and rebuild cascades on resize
        final currentMode = ref.read(chatLayoutModeProvider);
        if (currentMode != mode) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(chatLayoutModeProvider.notifier).state = mode;
          });
        }

        switch (mode) {
          case ChatLayoutMode.mobile:
            return const _MobileLayout();
          case ChatLayoutMode.tablet:
            return const _TabletLayout();
          case ChatLayoutMode.desktop:
            return const _DesktopLayout();
        }
      },
    );
  }
}

/// Mobile: session list only; navigation handled by SessionListPanel push.
class _MobileLayout extends StatelessWidget {
  const _MobileLayout();

  @override
  Widget build(BuildContext context) {
    return const SessionListPanel();
  }
}

/// Tablet: two-column layout — session list (narrow) + chat content (expanded).
class _TabletLayout extends StatelessWidget {
  const _TabletLayout();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        // At 600px, 300px session list leaves only 300px for chat.
        // Cap at 40% of width (max 300px) to ensure chat gets enough space.
        final listWidth = constraints.maxWidth * 0.4 < 300
            ? constraints.maxWidth * 0.4
            : 300.0;

        return Row(
          children: [
            SizedBox(
              width: listWidth,
              child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.stone.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: const SessionListPanel(),
          ),
        ),
        const Expanded(child: ChatContentPanel()),
      ],
    );
      },
    );
  }
}

/// Desktop: three-column layout — workspace sidebar + session list + chat content.
class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        // Workspace sidebar
        SizedBox(
          width: 220,
          child: _WorkspaceSidebar(isDark: isDark),
        ),
        // Session list
        SizedBox(
          width: 300,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.stone.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: const SessionListPanel(),
          ),
        ),
        // Chat content
        const Expanded(child: ChatContentPanel()),
      ],
    );
  }
}

/// Workspace sidebar showing app header, workspace list, and workspace management.
class _WorkspaceSidebar extends ConsumerWidget {
  final bool isDark;

  const _WorkspaceSidebar({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspacesAsync = ref.watch(workspacesProvider);
    final activeSlug = ref.watch(activeWorkspaceProvider).valueOrNull;

    return Container(
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // App header
          Padding(
            padding: EdgeInsets.fromLTRB(Spacing.md, Spacing.lg, Spacing.md, Spacing.md),
            child: Row(
              children: [
                Icon(
                  Icons.paragliding,
                  size: 24,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                SizedBox(width: Spacing.sm),
                Text(
                  'Parachute',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleMedium,
                    fontWeight: FontWeight.w700,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ],
            ),
          ),

          // Divider
          Divider(
            height: 1,
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.stone.withValues(alpha: 0.2),
          ),

          // Workspaces section
          Padding(
            padding: EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xs),
            child: Text(
              'WORKSPACES',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),
          ),

          // "All Chats" option
          _WorkspaceItem(
            name: 'All Chats',
            icon: Icons.chat_bubble_outline,
            isActive: activeSlug == null,
            isDark: isDark,
            onTap: () => ref.read(activeWorkspaceProvider.notifier).setWorkspace(null),
          ),

          // Workspace list
          Expanded(
            child: workspacesAsync.when(
              data: (workspaces) {
                if (workspaces.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: Text(
                      'No workspaces yet',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary.withValues(alpha: 0.6)
                            : BrandColors.stone.withValues(alpha: 0.6),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: workspaces.length,
                  itemBuilder: (context, index) {
                    final ws = workspaces[index];
                    return _WorkspaceItem(
                      name: ws.name,
                      icon: _workspaceIcon(ws),
                      isActive: activeSlug == ws.slug,
                      isDark: isDark,
                      subtitle: ws.model ?? ws.defaultTrustLevel,
                      onTap: () => ref.read(activeWorkspaceProvider.notifier).setWorkspace(ws.slug),
                      onEdit: () async {
                        final saved = await EditWorkspaceDialog.show(context, ws);
                        if (saved == true) ref.invalidate(workspacesProvider);
                      },
                      onDelete: () async {
                        final confirmed = await confirmDeleteWorkspace(context, ws);
                        if (!confirmed) return;
                        final service = ref.read(workspaceServiceProvider);
                        await service.deleteWorkspace(ws.slug);
                        ref.invalidate(workspacesProvider);
                        if (activeSlug == ws.slug) {
                          ref.read(activeWorkspaceProvider.notifier).setWorkspace(null);
                        }
                      },
                    );
                  },
                );
              },
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (_, __) => Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: Text(
                  'Could not load workspaces',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: BrandColors.error,
                  ),
                ),
              ),
            ),
          ),

          // Divider
          Divider(
            height: 1,
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.stone.withValues(alpha: 0.2),
          ),

          // New workspace button
          InkWell(
            onTap: () => _showCreateWorkspaceDialog(context, ref),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
              child: Row(
                children: [
                  Icon(
                    Icons.add,
                    size: 18,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  SizedBox(width: Spacing.sm),
                  Text(
                    'New Workspace',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontWeight: FontWeight.w500,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: Spacing.sm),
        ],
      ),
    );
  }

  IconData _workspaceIcon(Workspace ws) {
    final tl = TrustLevel.fromString(ws.defaultTrustLevel);
    return tl == TrustLevel.sandboxed ? Icons.shield_outlined : Icons.workspaces_outline;
  }

  void _showCreateWorkspaceDialog(BuildContext context, WidgetRef ref) {
    CreateWorkspaceDialog.show(
      context,
      onCreated: (ws) {
        ref.invalidate(workspacesProvider);
        ref.read(activeWorkspaceProvider.notifier).setWorkspace(ws.slug);
      },
    );
  }
}

/// Single workspace item in the sidebar.
class _WorkspaceItem extends StatelessWidget {
  final String name;
  final IconData icon;
  final bool isActive;
  final bool isDark;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _WorkspaceItem({
    required this.name,
    required this.icon,
    required this.isActive,
    required this.isDark,
    this.subtitle,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasActions = onEdit != null || onDelete != null;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
        color: isActive
            ? (isDark
                ? BrandColors.nightForest.withValues(alpha: 0.15)
                : BrandColors.forest.withValues(alpha: 0.08))
            : Colors.transparent,
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive
                  ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.stone),
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive
                          ? (isDark ? BrandColors.nightText : BrandColors.charcoal)
                          : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                            : BrandColors.stone.withValues(alpha: 0.7),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (hasActions)
              SizedBox(
                width: 24,
                height: 24,
                child: PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  icon: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  ),
                  onSelected: (value) {
                    if (value == 'edit') onEdit?.call();
                    if (value == 'delete') onDelete?.call();
                  },
                  itemBuilder: (context) => [
                    if (onEdit != null)
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (onDelete != null)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete', style: TextStyle(color: BrandColors.error)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
