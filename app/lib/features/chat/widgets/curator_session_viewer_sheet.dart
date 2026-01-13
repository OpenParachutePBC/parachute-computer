import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/curator_session.dart';
import '../providers/chat_providers.dart';

/// Bottom sheet showing curator session - focused on what the curator DID
///
/// Design principles:
/// - Collapse verbose context messages by default
/// - Highlight tool calls (title updates, log entries) prominently
/// - Show clear summary of curator actions at top
/// - Make it easy to understand what changed
class CuratorSessionViewerSheet extends ConsumerStatefulWidget {
  final String sessionId;

  const CuratorSessionViewerSheet({
    super.key,
    required this.sessionId,
  });

  /// Shows the curator session viewer sheet
  static Future<void> show(BuildContext context, String sessionId) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CuratorSessionViewerSheet(sessionId: sessionId),
    );
  }

  @override
  ConsumerState<CuratorSessionViewerSheet> createState() =>
      _CuratorSessionViewerSheetState();
}

class _CuratorSessionViewerSheetState
    extends ConsumerState<CuratorSessionViewerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isTriggering = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _triggerCurator() async {
    setState(() => _isTriggering = true);
    try {
      final trigger = ref.read(triggerCuratorProvider);
      await trigger(widget.sessionId);
      // Refresh both providers
      ref.invalidate(curatorInfoProvider(widget.sessionId));
      ref.invalidate(curatorMessagesProvider(widget.sessionId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error triggering curator: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTriggering = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.xl),
        ),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: Spacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
              borderRadius: Radii.pill,
            ),
          ),

          // Header with tabs
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.md, 0),
            child: Row(
              children: [
                Icon(
                  Icons.auto_fix_high,
                  size: 24,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  'Curator',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const Spacer(),
                // Trigger button
                IconButton(
                  onPressed: _isTriggering ? null : _triggerCurator,
                  icon: _isTriggering
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.play_arrow,
                          color: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                        ),
                  tooltip: 'Run curator now',
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(
                    Icons.close,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),

          // Tab bar
          TabBar(
            controller: _tabController,
            labelColor: isDark ? BrandColors.nightForest : BrandColors.forest,
            unselectedLabelColor:
                isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            indicatorColor:
                isDark ? BrandColors.nightForest : BrandColors.forest,
            tabs: const [
              Tab(text: 'Chat', icon: Icon(Icons.chat_bubble_outline, size: 18)),
              Tab(text: 'Tasks', icon: Icon(Icons.history, size: 18)),
            ],
          ),

          const Divider(height: 1),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _CuratorChatView(sessionId: widget.sessionId),
                _CuratorTasksView(sessionId: widget.sessionId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Chat view showing the curator's conversation
///
/// Shows a summary header with latest actions, then the conversation
/// with context messages collapsed by default.
class _CuratorChatView extends ConsumerWidget {
  final String sessionId;

  const _CuratorChatView({required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final messagesAsync = ref.watch(curatorMessagesProvider(sessionId));
    final infoAsync = ref.watch(curatorInfoProvider(sessionId));

    return messagesAsync.when(
      data: (data) {
        if (!data.hasMessages) {
          return _buildEmptyState(isDark, data.errorMessage);
        }
        return Column(
          children: [
            // Summary header showing latest curator actions
            infoAsync.when(
              data: (info) => _buildSummaryHeader(context, isDark, info),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
            // Message list
            Expanded(
              child: _buildChatList(context, isDark, data.messages),
            ),
          ],
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
          child: Text(
            'Error loading curator chat:\n$e',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),
      ),
    );
  }

  /// Build a summary header showing the latest curator actions
  Widget _buildSummaryHeader(BuildContext context, bool isDark, CuratorInfo info) {
    // Find the most recent completed task with results
    final recentTask = info.recentTasks
        .where((t) => t.status == CuratorTaskStatus.completed && t.result != null)
        .toList();

    if (recentTask.isEmpty) return const SizedBox.shrink();

    final latest = recentTask.first;
    final result = latest.result!;

    // Only show if there are actual actions
    if (!result.titleUpdated && !result.logged && result.actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.all(Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.15)
            : BrandColors.forest.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? BrandColors.nightForest.withValues(alpha: 0.3)
              : BrandColors.forest.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 16,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                'Latest Actions',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          // Show what was updated
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              if (result.titleUpdated && result.newTitle != null)
                _buildActionChip(
                  isDark,
                  icon: Icons.title,
                  label: 'Title: "${result.newTitle}"',
                ),
              if (result.logged)
                _buildActionChip(
                  isDark,
                  icon: Icons.edit_note,
                  label: 'Updated log',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(bool isDark, {required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isDark ? BrandColors.nightText : BrandColors.charcoal),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, String? message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              message ?? 'No curator conversation yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'The curator will start a conversation after\nyour first chat message.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                    : BrandColors.driftwood.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList(
    BuildContext context,
    bool isDark,
    List<CuratorMessage> messages,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(Spacing.md),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _CuratorMessageBubble(
          message: message,
          isDark: isDark,
        );
      },
    );
  }
}

/// A single message bubble in the curator chat
///
/// User (context) messages are collapsed by default since they're verbose.
/// Assistant messages with tool calls are shown prominently.
class _CuratorMessageBubble extends StatefulWidget {
  final CuratorMessage message;
  final bool isDark;

  const _CuratorMessageBubble({
    required this.message,
    required this.isDark,
  });

  @override
  State<_CuratorMessageBubble> createState() => _CuratorMessageBubbleState();
}

class _CuratorMessageBubbleState extends State<_CuratorMessageBubble> {
  // Context messages start collapsed, curator responses start expanded
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    // Collapse user (context) messages by default - they're verbose
    // Expand assistant messages - they show what curator did
    _isExpanded = !widget.message.isUser;
  }

  /// Get a preview of the content (first line or first N chars)
  String _getPreview(String content) {
    if (content.isEmpty) return '';
    final firstLine = content.split('\n').first;
    if (firstLine.length > 80) {
      return '${firstLine.substring(0, 77)}...';
    }
    return firstLine;
  }

  /// Check if content is long enough to warrant collapsing
  bool _isLongContent(String content) {
    return content.length > 200 || content.split('\n').length > 3;
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.isUser;
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isUser
        ? (widget.isDark
            ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
            : BrandColors.driftwood.withValues(alpha: 0.1))
        : (widget.isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone);

    final hasLongContent = _isLongContent(widget.message.content);
    final showCollapsed = isUser && hasLongContent && !_isExpanded;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          // Role label with expand/collapse for context messages
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: InkWell(
              onTap: hasLongContent ? () => setState(() => _isExpanded = !_isExpanded) : null,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isUser ? Icons.description_outlined : Icons.auto_fix_high,
                    size: 14,
                    color: isUser
                        ? (widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                        : (widget.isDark ? BrandColors.nightForest : BrandColors.forest),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isUser ? 'Context' : 'Curator',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      fontWeight: FontWeight.w500,
                      color: isUser
                          ? (widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                          : (widget.isDark ? BrandColors.nightForest : BrandColors.forest),
                    ),
                  ),
                  if (isUser && hasLongContent) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Message content
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Text content - collapsed or expanded
                if (widget.message.content.isNotEmpty)
                  showCollapsed
                      ? Text(
                          _getPreview(widget.message.content),
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: widget.isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : SelectableText(
                          widget.message.content,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodyMedium,
                            color: widget.isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                        ),

                // Tool calls - always shown prominently
                if (widget.message.hasToolCalls) ...[
                  if (widget.message.content.isNotEmpty)
                    const SizedBox(height: Spacing.sm),
                  ...widget.message.toolCalls!.map((tool) => _ToolCallChip(
                        tool: tool,
                        isDark: widget.isDark,
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip showing a tool call
class _ToolCallChip extends StatefulWidget {
  final CuratorToolCall tool;
  final bool isDark;

  const _ToolCallChip({
    required this.tool,
    required this.isDark,
  });

  @override
  State<_ToolCallChip> createState() => _ToolCallChipState();
}

class _ToolCallChipState extends State<_ToolCallChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final toolColor = widget.isDark ? BrandColors.nightForest : BrandColors.forest;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: toolColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: toolColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getToolIcon(widget.tool.displayName),
                    size: 14,
                    color: toolColor,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    widget.tool.displayName,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontWeight: FontWeight.w500,
                      color: toolColor,
                    ),
                  ),
                  if (widget.tool.input.isNotEmpty) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: toolColor,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Expanded tool input
          if (_expanded && widget.tool.input.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: Spacing.xs),
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? BrandColors.nightSurface
                    : BrandColors.softWhite,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: widget.isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.driftwood.withValues(alpha: 0.2),
                ),
              ),
              child: SelectableText(
                _formatJson(widget.tool.input),
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  fontFamily: 'monospace',
                  color: widget.isDark
                      ? BrandColors.nightText
                      : BrandColors.charcoal,
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _getToolIcon(String toolName) {
    switch (toolName) {
      case 'update_title':
        return Icons.title;
      case 'get_session_log':
        return Icons.history_edu;
      case 'update_session_log':
        return Icons.edit_note;
      case 'log_activity':
        return Icons.note_add;
      case 'get_session_info':
        return Icons.info_outline;
      default:
        return Icons.build;
    }
  }

  String _formatJson(Map<String, dynamic> input) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(input);
  }
}

/// Tasks view showing curator task history
class _CuratorTasksView extends ConsumerWidget {
  final String sessionId;

  const _CuratorTasksView({required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final infoAsync = ref.watch(curatorInfoProvider(sessionId));

    return infoAsync.when(
      data: (info) {
        if (info.recentTasks.isEmpty) {
          return _buildEmptyState(isDark);
        }
        return _buildTaskList(context, isDark, info);
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
          child: Text(
            'Error loading task history:\n$e',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 48,
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'No task history yet',
              style: TextStyle(
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList(BuildContext context, bool isDark, CuratorInfo info) {
    return ListView(
      padding: const EdgeInsets.all(Spacing.md),
      children: [
        // Status card
        _buildStatusCard(isDark, info),
        const SizedBox(height: Spacing.lg),

        // Task history
        Text(
          'Recent Tasks',
          style: TextStyle(
            fontSize: TypographyTokens.titleSmall,
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ...info.recentTasks.map((task) => _TaskCard(task: task, isDark: isDark)),
      ],
    );
  }

  Widget _buildStatusCard(bool isDark, CuratorInfo info) {
    final curator = info.curatorSession;

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
              : BrandColors.driftwood.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            curator != null ? Icons.check_circle : Icons.pending,
            size: 20,
            color: curator != null
                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                : (isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood),
          ),
          const SizedBox(width: Spacing.sm),
          Text(
            curator != null ? 'Curator Active' : 'No Curator Yet',
            style: TextStyle(
              fontSize: TypographyTokens.bodyLarge,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const Spacer(),
          _buildStatBadge(
            isDark,
            label: 'Tasks',
            count: info.completedTaskCount,
            color: BrandColors.forest,
          ),
          const SizedBox(width: Spacing.sm),
          _buildStatBadge(
            isDark,
            label: 'Updates',
            count: info.tasksWithUpdates,
            color: BrandColors.warning,
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(
    bool isDark, {
    required String label,
    required int count,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count.toString(),
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color:
                  isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }
}

/// A card showing a single curator task
class _TaskCard extends StatelessWidget {
  final CuratorTask task;
  final bool isDark;

  const _TaskCard({required this.task, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor(task.status);

    return Card(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
              : BrandColors.driftwood.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  task.status.displayName,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    fontWeight: FontWeight.w500,
                    color: statusColor,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTime(task.queuedAt),
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: [
                _buildChip(
                  isDark,
                  icon: Icons.flash_on,
                  label: task.triggerTypeDisplay,
                ),
                if (task.result != null) ...[
                  if (task.result!.titleUpdated)
                    _buildChip(
                      isDark,
                      icon: Icons.title,
                      label: 'Title',
                      color: BrandColors.forest,
                    ),
                  if (task.result!.logged)
                    _buildChip(
                      isDark,
                      icon: Icons.note_add,
                      label: 'Logged',
                      color: BrandColors.warning,
                    ),
                  if (task.result!.noChanges)
                    _buildChip(
                      isDark,
                      icon: Icons.check,
                      label: 'No changes',
                    ),
                ],
              ],
            ),
            // Show new title if updated
            if (task.result?.newTitle != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                '→ "${task.result!.newTitle}"',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  fontStyle: FontStyle.italic,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChip(
    bool isDark, {
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final chipColor = color ??
        (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: chipColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: chipColor,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(CuratorTaskStatus status) {
    switch (status) {
      case CuratorTaskStatus.pending:
        return BrandColors.warning;
      case CuratorTaskStatus.running:
        return BrandColors.forest;
      case CuratorTaskStatus.completed:
        return BrandColors.forest;
      case CuratorTaskStatus.failed:
        return BrandColors.error;
    }
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour);
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute $amPm';
  }
}
