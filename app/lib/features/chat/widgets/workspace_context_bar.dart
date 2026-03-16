import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/container_env.dart';
import '../providers/container_providers.dart';
import '../screens/container_file_browser_screen.dart';

/// Unified workspace context bar shown at the top of the session list.
///
/// Replaces both the desktop sidebar and the mobile/tablet filter chip with
/// a single widget that works identically on every screen size.
///
/// Shows the current workspace name (tappable → picker), session count,
/// and quick-action icons (files, settings) when a workspace is selected.
class WorkspaceContextBar extends ConsumerWidget {
  /// Called when the user taps the "new chat" action.
  final VoidCallback onNewChat;

  /// Called when the user taps the archive toggle.
  final VoidCallback onToggleArchive;

  /// Whether we're currently showing archived sessions.
  final bool showArchived;

  const WorkspaceContextBar({
    super.key,
    required this.onNewChat,
    required this.onToggleArchive,
    required this.showArchived,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeSlug = ref.watch(activeContainerProvider).valueOrNull;
    final containersAsync = ref.watch(containersProvider);
    final allContainersAsync = ref.watch(allContainersProvider);
    final counts = ref.watch(containerSessionCountsProvider);

    // Resolve the display name for the active workspace
    final activeDisplayName = containersAsync.whenOrNull(
      data: (envs) {
        if (activeSlug == null) return null;
        final match = envs.where((e) => e.slug == activeSlug);
        return match.isNotEmpty ? match.first.displayName : activeSlug;
      },
    );

    // Check if active container is an unnamed sandbox (not yet a workspace)
    final isActiveUnnamed = activeSlug != null &&
        (allContainersAsync.whenOrNull(
              data: (all) =>
                  all.firstWhereOrNull((e) => e.slug == activeSlug)?.isWorkspace == false,
            ) ??
            false);
    final isActiveNamed = activeSlug != null && !isActiveUnnamed;

    final sessionCount = activeSlug != null
        ? (counts[activeSlug] ?? 0)
        : (counts[null] ?? 0);

    return Container(
      padding: EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.xs, Spacing.xs),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.stone.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: workspace name + action icons
          Row(
            children: [
              // Tappable workspace name
              Expanded(
                child: GestureDetector(
                  onTap: () => _showWorkspacePicker(context, ref, isDark),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.expand_more,
                        size: 20,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                      ),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(
                          showArchived
                              ? 'Archived'
                              : (activeDisplayName ?? 'All Chats'),
                          style: TextStyle(
                            fontSize: TypographyTokens.titleMedium,
                            fontWeight: FontWeight.w600,
                            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Quick actions (only when workspace is selected)
              if (activeSlug != null) ...[
                _ActionIcon(
                  icon: Icons.folder_outlined,
                  tooltip: 'Files',
                  isDark: isDark,
                  onTap: () => _openFiles(
                    context,
                    activeSlug,
                    activeDisplayName ?? activeSlug,
                  ),
                ),
                // Gear icon only for named workspaces (unnamed ones get the promotion banner)
                if (isActiveNamed)
                  _ActionIcon(
                    icon: Icons.settings_outlined,
                    tooltip: 'Workspace Settings',
                    isDark: isDark,
                    onTap: () => ContainerSettingsSheet.show(context, ref, activeSlug),
                  ),
              ],

              // Archive toggle
              _ActionIcon(
                icon: showArchived ? Icons.inbox : Icons.archive_outlined,
                tooltip: showArchived ? 'Show active' : 'Show archived',
                isDark: isDark,
                onTap: onToggleArchive,
              ),

              // New chat
              _ActionIcon(
                icon: Icons.add,
                tooltip: 'New Chat',
                isDark: isDark,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
                onTap: onNewChat,
              ),
            ],
          ),

          // Promotion banner for unnamed workspaces
          if (isActiveUnnamed)
            _WorkspacePromotionBanner(slug: activeSlug),

          // Row 2: session count subtitle
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 2),
            child: Text(
              showArchived
                  ? 'archived conversations'
                  : '$sessionCount conversation${sessionCount == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showWorkspacePicker(BuildContext context, WidgetRef ref, bool isDark) {
    final containersAsync = ref.read(containersProvider);
    final activeSlug = ref.read(activeContainerProvider).valueOrNull;
    final counts = ref.read(containerSessionCountsProvider);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightSurface : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Padding(
                  padding: EdgeInsets.only(top: Spacing.sm),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(Spacing.md),
                  child: Text(
                    'Choose Workspace',
                    style: TextStyle(
                      fontSize: TypographyTokens.titleSmall,
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightText : BrandColors.ink,
                    ),
                  ),
                ),

                // "All Chats" option
                _WorkspacePickerItem(
                  name: 'All Chats',
                  icon: Icons.chat_bubble_outline,
                  count: counts[null] ?? 0,
                  isActive: activeSlug == null,
                  isDark: isDark,
                  onTap: () {
                    ref.read(activeContainerProvider.notifier).setContainer(null);
                    Navigator.pop(sheetContext);
                  },
                ),

                // Named containers
                Flexible(
                  child: SingleChildScrollView(
                    child: containersAsync.when(
                      data: (envs) {
                        if (envs.isEmpty) {
                          return Padding(
                            padding: EdgeInsets.all(Spacing.lg),
                            child: Text(
                              'No named workspaces yet',
                              style: TextStyle(
                                color: isDark
                                    ? BrandColors.nightTextSecondary
                                    : BrandColors.driftwood,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: envs.map((env) {
                            return _WorkspacePickerItem(
                              name: env.displayName,
                              icon: Icons.dns_outlined,
                              count: counts[env.slug] ?? 0,
                              isActive: env.slug == activeSlug,
                              isDark: isDark,
                              onTap: () {
                                ref
                                    .read(activeContainerProvider.notifier)
                                    .setContainer(env.slug);
                                Navigator.pop(sheetContext);
                              },
                            );
                          }).toList(),
                        );
                      },
                      loading: () => Padding(
                        padding: EdgeInsets.all(Spacing.lg),
                        child: const CircularProgressIndicator(),
                      ),
                      error: (_, __) => Padding(
                        padding: EdgeInsets.all(Spacing.lg),
                        child: Text(
                          'Failed to load workspaces',
                          style: TextStyle(color: BrandColors.error),
                        ),
                      ),
                    ),
                  ),
                ),

                // "+ New Workspace" action
                Divider(
                  height: 1,
                  color: isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.stone.withValues(alpha: 0.2),
                ),
                ListTile(
                  leading: Icon(
                    Icons.add,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  title: Text(
                    'New Workspace',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showCreateWorkspaceDialog(context, ref, isDark);
                  },
                ),
                SizedBox(height: Spacing.sm),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCreateWorkspaceDialog(BuildContext context, WidgetRef ref, bool isDark) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Workspace'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'e.g., My Project',
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
                final service = ref.read(containerServiceProvider);
                final created = await service.createContainer(
                  ContainerEnvCreate(displayName: name),
                );
                ref.invalidate(containersProvider);
                ref
                    .read(activeContainerProvider.notifier)
                    .setContainer(created.slug);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to create workspace: $e')),
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

  void _openFiles(BuildContext context, String slug, String displayName) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ContainerFileBrowserScreen(
          slug: slug,
          displayName: displayName,
        ),
      ),
    );
  }

}

/// Small icon button used in the context bar action row.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final Color? color;
  final VoidCallback onTap;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 20,
        color: color ?? (isDark ? BrandColors.nightTextSecondary : BrandColors.stone),
      ),
      onPressed: onTap,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
    );
  }
}

/// Single item in the workspace picker bottom sheet.
class _WorkspacePickerItem extends StatelessWidget {
  final String name;
  final IconData icon;
  final int count;
  final bool isActive;
  final bool isDark;
  final VoidCallback onTap;

  const _WorkspacePickerItem({
    required this.name,
    required this.icon,
    required this.count,
    required this.isActive,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: isActive
            ? (isDark ? BrandColors.nightForest : BrandColors.forest)
            : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
      ),
      title: Text(
        name,
        style: TextStyle(
          color: isDark ? BrandColors.nightText : BrandColors.ink,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.check,
              size: 18,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Bottom sheet for workspace settings (rename and delete).
class ContainerSettingsSheet extends ConsumerStatefulWidget {
  final String slug;

  const ContainerSettingsSheet({super.key, required this.slug});

  static Future<void> show(BuildContext context, WidgetRef ref, String slug) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContainerSettingsSheet(slug: slug),
    );
  }

  @override
  ConsumerState<ContainerSettingsSheet> createState() =>
      _ContainerSettingsSheetState();
}

class _ContainerSettingsSheetState
    extends ConsumerState<ContainerSettingsSheet> {
  late TextEditingController _nameController;
  bool _isSaving = false;
  String? _error;

  bool _controllersPopulated = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final service = ref.read(containerServiceProvider);
      await service.updateContainer(
        widget.slug,
        displayName: name,
      );
      ref.invalidate(containersProvider);
      ref.invalidate(allContainersProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Save failed: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _delete() async {
    final workspaceName = _nameController.text;
    final sessionCount = ref.read(containerSessionCountsProvider)[widget.slug] ?? 0;
    final messenger = ScaffoldMessenger.of(context);

    final confirmController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final nameMatches = confirmController.text == workspaceName;
            return AlertDialog(
              title: Text('Delete "$workspaceName"?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (sessionCount > 0)
                    Padding(
                      padding: EdgeInsets.only(bottom: Spacing.sm),
                      child: Text(
                        'This workspace has $sessionCount conversation${sessionCount == 1 ? '' : 's'} '
                        'that will be ungrouped.',
                      ),
                    ),
                  const Text(
                    'The sandbox environment and all files will be permanently deleted.',
                  ),
                  SizedBox(height: Spacing.md),
                  Text(
                    'Type the workspace name to confirm:',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: TypographyTokens.labelSmall,
                    ),
                  ),
                  SizedBox(height: Spacing.xs),
                  TextField(
                    controller: confirmController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: workspaceName,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.sm,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Spacing.xs),
                      ),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: nameMatches
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        );
      },
    );
    confirmController.dispose();
    if (confirmed != true) return;

    try {
      final service = ref.read(containerServiceProvider);
      await service.deleteContainer(widget.slug);
      ref.invalidate(containersProvider);
      ref.invalidate(allContainersProvider);
      final activeSlug = ref.read(activeContainerProvider).valueOrNull;
      if (activeSlug == widget.slug) {
        ref.read(activeContainerProvider.notifier).setContainer(null);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Populate controller once when data first arrives — ref.listen runs
    // after the frame, not mid-build, so side effects are safe here.
    ref.listen<AsyncValue<List<ContainerEnv>>>(containersProvider, (prev, next) {
      if (_controllersPopulated) return;
      next.whenData((envs) {
        final match = envs.firstWhereOrNull((e) => e.slug == widget.slug);
        if (match != null) {
          _nameController.text = match.displayName;
          _controllersPopulated = true;
        }
      });
    });

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: EdgeInsets.only(
          left: Spacing.lg,
          right: Spacing.lg,
          top: Spacing.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: Spacing.md),

            Text(
              'Workspace Settings',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.md),

            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Display name
                    Text(
                      'Name',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                    SizedBox(height: Spacing.xs),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        hintText: 'Workspace name',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Spacing.xs),
                        ),
                      ),
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightText : BrandColors.ink,
                      ),
                    ),

                    if (_error != null) ...[
                      SizedBox(height: Spacing.sm),
                      Text(
                        _error!,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: BrandColors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            SizedBox(height: Spacing.lg),

            // Delete button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _isSaving ? null : _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: BrandColors.error,
                  side: BorderSide(color: BrandColors.error),
                  padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                ),
                child: const Text('Delete Workspace'),
              ),
            ),
            SizedBox(height: Spacing.sm),

            // Save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isDark ? BrandColors.nightForest : BrandColors.forest,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline banner shown when the active workspace is unnamed.
///
/// Provides a text field + "Name" button so users can promote an unnamed
/// container to a named workspace directly from the context bar.
class _WorkspacePromotionBanner extends ConsumerStatefulWidget {
  final String slug;

  const _WorkspacePromotionBanner({required this.slug});

  @override
  ConsumerState<_WorkspacePromotionBanner> createState() =>
      _WorkspacePromotionBannerState();
}

class _WorkspacePromotionBannerState
    extends ConsumerState<_WorkspacePromotionBanner> {
  final _controller = TextEditingController();
  bool _isNaming = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _nameWorkspace() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isNaming = true);
    try {
      final service = ref.read(containerServiceProvider);
      await service.updateContainer(widget.slug, displayName: name);
      ref.invalidate(containersProvider);
      ref.invalidate(allContainersProvider);
      if (mounted) {
        _controller.clear();
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
      if (mounted) setState(() => _isNaming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: EdgeInsets.only(
        left: Spacing.sm,
        right: Spacing.xs,
        top: Spacing.xs,
      ),
      padding: EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightForest : BrandColors.forest)
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Spacing.xs),
        border: Border.all(
          color: (isDark ? BrandColors.nightForest : BrandColors.forest)
              .withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.edit_outlined,
            size: 14,
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
          SizedBox(width: Spacing.xs),
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'Name this workspace',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Spacing.xs),
                  ),
                ),
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
                onSubmitted: (_) => _nameWorkspace(),
              ),
            ),
          ),
          SizedBox(width: Spacing.sm),
          SizedBox(
            height: 30,
            child: FilledButton(
              onPressed: _isNaming ? null : _nameWorkspace,
              style: FilledButton.styleFrom(
                backgroundColor:
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
              ),
              child: _isNaming
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      'Name',
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
