import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../screens/claude_code_import_screen.dart';

// State provider for showing archived sessions
final _showArchivedSessionsProvider = StateProvider<bool>((ref) => false);

/// Bottom sheet for selecting and managing chat sessions
class SessionSelector extends ConsumerWidget {
  const SessionSelector({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const SessionSelector(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final showArchived = ref.watch(_showArchivedSessionsProvider);
    final sessionsAsync = showArchived
        ? ref.watch(archivedSessionsProvider)
        : ref.watch(chatSessionsProvider);
    final currentSessionId = ref.watch(currentSessionIdProvider);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.xl),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: Spacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              borderRadius: Radii.pill,
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Row(
              children: [
                Text(
                  showArchived ? 'Archived Sessions' : 'Chat Sessions',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const Spacer(),
                // Toggle archived sessions button
                IconButton(
                  onPressed: () {
                    ref.read(_showArchivedSessionsProvider.notifier).state = !showArchived;
                  },
                  icon: Icon(
                    showArchived ? Icons.inbox : Icons.archive,
                    size: 20,
                  ),
                  tooltip: showArchived ? 'Show Active' : 'Show Archived',
                  style: IconButton.styleFrom(
                    foregroundColor:
                        isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
                // Import from Claude Code button
                if (!showArchived)
                  IconButton(
                    onPressed: () async {
                      final sessionId = await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (context) => const ClaudeCodeImportScreen(),
                        ),
                      );
                      if (sessionId != null && context.mounted) {
                        ref.read(switchSessionProvider)(sessionId);
                        Navigator.pop(context);
                      }
                    },
                    icon: const Icon(Icons.download, size: 20),
                    tooltip: 'Import from Claude Code',
                    style: IconButton.styleFrom(
                      foregroundColor:
                          isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                    ),
                  ),
                // New chat button
                if (!showArchived)
                  TextButton.icon(
                    onPressed: () {
                      ref.read(newChatProvider)();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New Chat'),
                    style: TextButton.styleFrom(
                      foregroundColor:
                          isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                  ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Sessions list
          Flexible(
            child: sessionsAsync.when(
              data: (sessions) {
                if (sessions.isEmpty) {
                  return _buildEmptyState(context, isDark);
                }

                return ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isSelected = session.id == currentSessionId;

                    return _SessionTile(
                      session: session,
                      isSelected: isSelected,
                      isLocal: session.isLocal,
                      showArchived: showArchived,
                      onTap: () {
                        ref.read(switchSessionProvider)(session.id);
                        Navigator.pop(context);
                      },
                      onDelete: session.isLocal
                          ? null // Can't delete local-only sessions via API
                          : () async {
                              final confirmed = await _confirmDelete(context, isDark);
                              if (confirmed == true) {
                                await ref.read(deleteSessionProvider)(session.id);
                              }
                            },
                      onArchive: session.isLocal
                          ? null // Can't archive local-only sessions via API
                          : () async {
                              await ref.read(archiveSessionProvider)(session.id);
                            },
                      onUnarchive: session.isLocal
                          ? null // Can't unarchive local-only sessions via API
                          : () async {
                              await ref.read(unarchiveSessionProvider)(session.id);
                            },
                    );
                  },
                );
              },
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(Spacing.xl),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: BrandColors.error,
                        size: 48,
                      ),
                      const SizedBox(height: Spacing.md),
                      Text(
                        'Failed to load sessions',
                        style: TextStyle(
                          color: isDark
                              ? BrandColors.nightText
                              : BrandColors.charcoal,
                        ),
                      ),
                      const SizedBox(height: Spacing.sm),
                      TextButton(
                        onPressed: () => ref.invalidate(chatSessionsProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          const SizedBox(height: Spacing.md),
          Text(
            'No chat sessions yet',
            style: TextStyle(
              fontSize: TypographyTokens.bodyLarge,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Start a new chat to get started',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, bool isDark) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        shape: RoundedRectangleBorder(borderRadius: Radii.card),
        title: Text(
          'Delete Session?',
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        content: Text(
          'This will permanently delete this chat session and all its messages.',
          style: TextStyle(
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: BrandColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  final bool isSelected;
  final bool isLocal;
  final bool showArchived;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onArchive;
  final VoidCallback? onUnarchive;

  const _SessionTile({
    required this.session,
    required this.isSelected,
    this.isLocal = false,
    this.showArchived = false,
    required this.onTap,
    this.onDelete,
    this.onArchive,
    this.onUnarchive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Build the tile content
    final tile = ListTile(
      onTap: onTap,
      selected: isSelected,
      selectedTileColor: isDark
          ? BrandColors.nightForest.withValues(alpha: 0.1)
          : BrandColors.forestMist.withValues(alpha: 0.5),
      leading: CircleAvatar(
        backgroundColor: isSelected
            ? (isDark ? BrandColors.nightForest : BrandColors.forest)
            : (isDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.stone),
        child: Icon(
          session.agentPath != null
              ? Icons.smart_toy_outlined
              : Icons.chat_bubble_outline,
          size: 18,
          color: isSelected
              ? Colors.white
              : (isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ),
          // Local indicator
          if (isLocal)
            Container(
              margin: const EdgeInsets.only(left: Spacing.xs),
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: BrandColors.warning.withValues(alpha: 0.2),
                borderRadius: Radii.badge,
              ),
              child: Text(
                'Local',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: BrandColors.warning,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        _formatDate(session.updatedAt ?? session.createdAt),
        style: TextStyle(
          fontSize: TypographyTokens.labelSmall,
          color: isDark
              ? BrandColors.nightTextSecondary
              : BrandColors.driftwood,
        ),
      ),
      trailing: isSelected
          ? Icon(
              Icons.check_circle,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
              size: 20,
            )
          : null,
    );

    // Wrap in Dismissible for swipe actions
    if (showArchived) {
      // Archived sessions: swipe to unarchive or delete
      if (onUnarchive != null || onDelete != null) {
        // Determine swipe direction based on available actions
        final direction = onUnarchive != null && onDelete != null
            ? DismissDirection.horizontal
            : onUnarchive != null
                ? DismissDirection.startToEnd
                : DismissDirection.endToStart;

        return Dismissible(
          key: Key(session.id),
          direction: direction,
          background: Container(
            alignment: onUnarchive != null ? Alignment.centerLeft : Alignment.centerRight,
            padding: EdgeInsets.only(
              left: onUnarchive != null ? Spacing.lg : 0,
              right: onDelete != null && onUnarchive == null ? Spacing.lg : 0,
            ),
            color: onUnarchive != null
                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                : BrandColors.error,
            child: Icon(
              onUnarchive != null ? Icons.unarchive : Icons.delete,
              color: Colors.white,
            ),
          ),
          secondaryBackground: onUnarchive != null && onDelete != null
              ? Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: Spacing.lg),
                  color: BrandColors.error,
                  child: const Icon(Icons.delete, color: Colors.white),
                )
              : null,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd && onUnarchive != null) {
              onUnarchive!();
            } else if (direction == DismissDirection.endToStart && onDelete != null) {
              onDelete!();
            }
            return false; // We handle the action in callbacks
          },
          child: tile,
        );
      }
    } else {
      // Active sessions: swipe to archive or delete
      if (onArchive != null || onDelete != null) {
        // Determine swipe direction based on available actions
        final direction = onArchive != null && onDelete != null
            ? DismissDirection.horizontal
            : onArchive != null
                ? DismissDirection.startToEnd
                : DismissDirection.endToStart;

        return Dismissible(
          key: Key(session.id),
          direction: direction,
          background: Container(
            alignment: onArchive != null ? Alignment.centerLeft : Alignment.centerRight,
            padding: EdgeInsets.only(
              left: onArchive != null ? Spacing.lg : 0,
              right: onDelete != null && onArchive == null ? Spacing.lg : 0,
            ),
            color: onArchive != null
                ? (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                : BrandColors.error,
            child: Icon(
              onArchive != null ? Icons.archive : Icons.delete,
              color: Colors.white,
            ),
          ),
          secondaryBackground: onArchive != null && onDelete != null
              ? Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: Spacing.lg),
                  color: BrandColors.error,
                  child: const Icon(Icons.delete, color: Colors.white),
                )
              : null,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd && onArchive != null) {
              onArchive!();
            } else if (direction == DismissDirection.endToStart && onDelete != null) {
              onDelete!();
            }
            return false; // We handle the action in callbacks
          },
          child: tile,
        );
      }
    }

    return tile;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${date.month}/${date.day}/${date.year}';
  }
}
