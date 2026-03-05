import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/chat_layout_provider.dart';
import '../models/project.dart';
import '../providers/project_providers.dart';
import '../widgets/session_list_panel.dart';
import '../widgets/chat_content_panel.dart';

/// Adaptive shell for the chat feature.
///
/// Uses LayoutBuilder to pick the right layout:
/// - **Mobile** (<600px): Just SessionListPanel; tapping a session pushes ChatScreen.
/// - **Tablet** (600–1199px): Two-column — session list + chat content side by side.
/// - **Desktop** (≥1200px): Three-column — container env sidebar + session list + chat content.
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

/// Desktop: three-column layout — container env sidebar + session list + chat content.
class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        // Container env sidebar
        SizedBox(
          width: 220,
          child: _ProjectSidebar(isDark: isDark),
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

/// Container env sidebar showing app header, env list, and create button.
class _ProjectSidebar extends ConsumerWidget {
  final bool isDark;

  const _ProjectSidebar({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containerEnvsAsync = ref.watch(projectsProvider);
    final activeSlug = ref.watch(activeProjectProvider).valueOrNull;

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

          // Environments section header
          Padding(
            padding: EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xs),
            child: Text(
              'ENVIRONMENTS',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),
          ),

          // "All Chats" option
          _EnvItem(
            name: 'All Chats',
            icon: Icons.chat_bubble_outline,
            isActive: activeSlug == null,
            isDark: isDark,
            onTap: () =>
                ref.read(activeProjectProvider.notifier).setProject(null),
          ),

          // Container env list
          Expanded(
            child: containerEnvsAsync.when(
              data: (envs) {
                if (envs.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.all(Spacing.md),
                    child: Text(
                      'No named environments yet',
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
                  itemCount: envs.length,
                  itemBuilder: (context, index) {
                    final env = envs[index];
                    return _EnvItem(
                      name: env.displayName,
                      icon: Icons.dns_outlined,
                      isActive: activeSlug == env.slug,
                      isDark: isDark,
                      onTap: () => ref
                          .read(activeProjectProvider.notifier)
                          .setProject(env.slug),
                      onDelete: () async {
                        final confirmed = await _confirmDeleteEnv(context, env.displayName);
                        if (!confirmed) return;
                        try {
                          final service = ref.read(projectServiceProvider);
                          await service.deleteProject(env.slug);
                          ref.invalidate(projectsProvider);
                          if (activeSlug == env.slug) {
                            ref
                                .read(activeProjectProvider.notifier)
                                .setProject(null);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to delete: $e')),
                            );
                          }
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
                  'Could not load environments',
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

          // New environment button
          InkWell(
            onTap: () => _showCreateEnvDialog(context, ref),
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
                    'New Env',
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

  Future<bool> _confirmDeleteEnv(BuildContext context, String displayName) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "$displayName"?'),
        content: const Text(
          'Sessions in this environment will be unlinked but not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showCreateEnvDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Environment'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'e.g., Work Projects',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(dialogContext);
              try {
                final service = ref.read(projectServiceProvider);
                final created = await service.createProject(
                  ProjectCreate(displayName: name),
                );
                ref.invalidate(projectsProvider);
                ref
                    .read(activeProjectProvider.notifier)
                    .setProject(created.slug);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to create environment: $e')),
                  );
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }
}

/// Single environment item in the sidebar.
class _EnvItem extends StatelessWidget {
  final String name;
  final IconData icon;
  final bool isActive;
  final bool isDark;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _EnvItem({
    required this.name,
    required this.icon,
    required this.isActive,
    required this.isDark,
    this.subtitle,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                          : (isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood),
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
            if (onDelete != null)
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
                    if (value == 'delete') onDelete?.call();
                  },
                  itemBuilder: (context) => [
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
