import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/settings/models/trust_level.dart';
import '../models/chat_session.dart';
import 'session_config_sheet.dart';

/// List item for displaying a chat session
///
/// Shows session title, agent name, timestamp, and swipe actions:
/// - Swipe left (start to end): Archive/Unarchive
/// - Swipe right (end to start): Delete with confirmation
class SessionListItem extends StatelessWidget {
  final ChatSession session;
  final VoidCallback onTap;
  final Future<void> Function()? onDelete;
  final Future<void> Function()? onArchive;
  final Future<void> Function()? onUnarchive;
  final bool isDark;

  const SessionListItem({
    super.key,
    required this.session,
    required this.onTap,
    this.onDelete,
    this.onArchive,
    this.onUnarchive,
    this.isDark = false,
  });

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          'This will permanently delete "${session.displayTitle}".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: BrandColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeDark = this.isDark || theme.brightness == Brightness.dark;

    // Determine swipe actions based on archive state
    final canArchive = !session.archived && onArchive != null;
    final canUnarchive = session.archived && onUnarchive != null;
    final hasLeftAction = canArchive || canUnarchive;
    final canDelete = onDelete != null;

    // Build the tile content
    final tileContent = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => SessionConfigSheet.show(context, session),
        borderRadius: Radii.card,
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: themeDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.softWhite,
            borderRadius: Radii.card,
            border: Border.all(
              color: themeDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              // Type icon
              _buildTypeIcon(themeDark),

              const SizedBox(width: Spacing.md),

              // Title and metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.displayTitle,
                            style: TextStyle(
                              fontSize: TypographyTokens.bodyMedium,
                              fontWeight: FontWeight.w500,
                              color: themeDark
                                  ? BrandColors.nightText
                                  : BrandColors.charcoal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Badges (shrink when space is tight)
                        Flexible(
                          flex: 0,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Pending approval badge
                              if (session.isPendingApproval)
                                _badge('Pending', Colors.amber, themeDark),
                              // Pending initialization badge
                              if (session.isPendingInitialization)
                                _badge('Setup', Colors.orange, themeDark),
                              // Archived badge
                              if (session.archived)
                                _badge(
                                  'Archived',
                                  themeDark
                                      ? BrandColors.nightTextSecondary
                                      : BrandColors.driftwood,
                                  themeDark,
                                ),
                              // Trust level badge (shown when not default 'trusted')
                              if (session.trustLevel != null && session.trustLevel != 'trusted')
                                _buildTrustBadge(session.trustLevel!, themeDark),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // First message preview for pending approval sessions
                    if (session.isPendingApproval && session.firstMessage != null) ...[
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        session.firstMessage!,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          fontStyle: FontStyle.italic,
                          color: themeDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: Spacing.xxs),
                    Row(
                      children: [
                        // Show source for bot or imported sessions
                        if (session.source.isBotSession) ...[
                          Flexible(
                            child: Text(
                              'via ${session.source.displayName}',
                              style: TextStyle(
                                fontSize: TypographyTokens.labelSmall,
                                color: themeDark
                                    ? BrandColors.nightForest
                                    : BrandColors.forest,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            ' • ',
                            style: TextStyle(
                              fontSize: TypographyTokens.labelSmall,
                              color: themeDark
                                  ? BrandColors.nightTextSecondary
                                  : BrandColors.driftwood,
                            ),
                          ),
                        ] else if (session.isImported) ...[
                          Flexible(
                            child: Text(
                              session.source.displayName,
                              style: TextStyle(
                                fontSize: TypographyTokens.labelSmall,
                                color: themeDark
                                    ? BrandColors.nightForest
                                    : BrandColors.forest,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            ' • ',
                            style: TextStyle(
                              fontSize: TypographyTokens.labelSmall,
                              color: themeDark
                                  ? BrandColors.nightTextSecondary
                                  : BrandColors.driftwood,
                            ),
                          ),
                        ] else if (session.agentName != null) ...[
                          Flexible(
                            child: Text(
                              session.agentName!,
                              style: TextStyle(
                                fontSize: TypographyTokens.labelSmall,
                                color: themeDark
                                    ? BrandColors.nightTurquoise
                                    : BrandColors.turquoise,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            ' • ',
                            style: TextStyle(
                              fontSize: TypographyTokens.labelSmall,
                              color: themeDark
                                  ? BrandColors.nightTextSecondary
                                  : BrandColors.driftwood,
                            ),
                          ),
                        ],
                        Text(
                          _formatTimestamp(session.updatedAt ?? session.createdAt),
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: themeDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Arrow
              Icon(
                Icons.chevron_right,
                size: 20,
                color: themeDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ],
          ),
        ),
      ),
    );

    // If no swipe actions, just return the tile
    if (!hasLeftAction && !canDelete) {
      return tileContent;
    }

    // Determine swipe direction and backgrounds
    final DismissDirection direction;
    Widget? background;
    Widget? secondaryBackground;

    if (hasLeftAction && canDelete) {
      // Both directions available
      direction = DismissDirection.horizontal;
      background = Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: Spacing.lg),
        decoration: BoxDecoration(
          color: canUnarchive
              ? (themeDark ? BrandColors.nightForest : BrandColors.forest)
              : (themeDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
          borderRadius: Radii.card,
        ),
        child: Icon(
          canUnarchive ? Icons.unarchive : Icons.archive,
          color: Colors.white,
        ),
      );
      secondaryBackground = Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Spacing.lg),
        decoration: BoxDecoration(
          color: BrandColors.error,
          borderRadius: Radii.card,
        ),
        child: const Icon(
          Icons.delete_outline,
          color: Colors.white,
        ),
      );
    } else if (hasLeftAction) {
      // Only left action (archive/unarchive)
      direction = DismissDirection.startToEnd;
      background = Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: Spacing.lg),
        decoration: BoxDecoration(
          color: canUnarchive
              ? (themeDark ? BrandColors.nightForest : BrandColors.forest)
              : (themeDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
          borderRadius: Radii.card,
        ),
        child: Icon(
          canUnarchive ? Icons.unarchive : Icons.archive,
          color: Colors.white,
        ),
      );
    } else {
      // Only delete action
      direction = DismissDirection.endToStart;
      background = Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Spacing.lg),
        decoration: BoxDecoration(
          color: BrandColors.error,
          borderRadius: Radii.card,
        ),
        child: const Icon(
          Icons.delete_outline,
          color: Colors.white,
        ),
      );
    }

    return Dismissible(
      key: Key(session.id),
      direction: direction,
      background: background,
      secondaryBackground: secondaryBackground,
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          // Archive or unarchive (no confirmation needed)
          if (canArchive) {
            await onArchive!();
          } else if (canUnarchive) {
            await onUnarchive!();
          }
          return false; // We handle the action in callbacks
        } else if (canDelete) {
          // Delete - show confirmation dialog
          final confirmed = await _confirmDelete(context);
          if (!confirmed) return false;
          await onDelete!();
          return true;
        }
        return false;
      },
      child: tileContent,
    );
  }

  Widget _buildTypeIcon(bool isDark) {
    // Show different icons based on source
    IconData icon;
    Color color;

    switch (session.source) {
      case ChatSource.chatgpt:
        icon = Icons.auto_awesome;
        color = BrandColors.turquoise;
        break;
      case ChatSource.claude:
        icon = Icons.psychology_outlined;
        color = BrandColors.forest;
        break;
      case ChatSource.telegram:
        icon = Icons.send;
        color = const Color(0xFF0088CC);
        break;
      case ChatSource.discord:
        icon = Icons.gamepad;
        color = const Color(0xFF5865F2);
        break;
      case ChatSource.other:
        icon = Icons.download_outlined;
        color = BrandColors.driftwood;
        break;
      case ChatSource.parachute:
        icon = Icons.chat_bubble_outline;
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
        break;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 18,
        color: color,
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${timestamp.month}/${timestamp.day}';
    }
  }

  Widget _badge(String text, Color color, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(left: Spacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.xs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: Radii.badge,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isDark ? color.withValues(alpha: 0.8) : color,
        ),
      ),
    );
  }

  Widget _buildTrustBadge(String trustLevelStr, bool isDark) {
    final tl = TrustLevel.fromString(trustLevelStr);
    final color = tl.iconColor(isDark);
    return Tooltip(
      message: tl.displayName,
      child: Container(
        margin: const EdgeInsets.only(left: Spacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: Radii.badge,
        ),
        child: Icon(
          tl.icon,
          size: 12,
          color: color,
        ),
      ),
    );
  }
}
