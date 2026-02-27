import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/bridge_run.dart';
import '../providers/bridge_providers.dart';
import '../providers/chat_session_providers.dart';

/// Bottom sheet showing the bridge agent's conversation with last run summary at the bottom.
class BridgeSessionViewerSheet extends ConsumerStatefulWidget {
  final String chatSessionId;

  const BridgeSessionViewerSheet({
    super.key,
    required this.chatSessionId,
  });

  static Future<void> show(BuildContext context, String chatSessionId) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          BridgeSessionViewerSheet(chatSessionId: chatSessionId),
    );
  }

  @override
  ConsumerState<BridgeSessionViewerSheet> createState() =>
      _BridgeSessionViewerSheetState();
}

class _BridgeSessionViewerSheetState
    extends ConsumerState<BridgeSessionViewerSheet> {
  bool _isTriggering = false;

  Future<void> _triggerBridge() async {
    setState(() => _isTriggering = true);
    try {
      final trigger = ref.read(triggerBridgeProvider);
      await trigger(widget.chatSessionId);
      ref.invalidate(sessionWithMessagesProvider(widget.chatSessionId));
      ref.invalidate(bridgeMessagesProvider(widget.chatSessionId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error triggering bridge: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isTriggering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messagesAsync = ref.watch(bridgeMessagesProvider(widget.chatSessionId));
    final sessionAsync = ref.watch(sessionWithMessagesProvider(widget.chatSessionId));
    final lastRun = sessionAsync.valueOrNull?.session.bridgeLastRun;

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
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              borderRadius: Radii.pill,
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.md, 0),
            child: Row(
              children: [
                Icon(Icons.auto_fix_high, size: 24, color: BrandColors.turquoise),
                const SizedBox(width: Spacing.sm),
                Text(
                  'Bridge',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _isTriggering ? null : _triggerBridge,
                  icon: _isTriggering
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.play_arrow, color: BrandColors.turquoise),
                  tooltip: 'Run bridge now',
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(
                    Icons.close,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Conversation list + last run at the bottom
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty && lastRun == null) {
                  return _EmptyState(
                    icon: Icons.chat_bubble_outline,
                    message: 'No bridge conversation yet',
                    detail: 'The bridge will start after\nyour first chat message.',
                    isDark: isDark,
                  );
                }

                final itemCount = messages.length + (lastRun != null ? 1 : 0);
                return ListView.builder(
                  padding: const EdgeInsets.all(Spacing.md),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    // Last item is the run summary card (if present)
                    if (lastRun != null && index == messages.length) {
                      return _LastRunCard(run: lastRun, isDark: isDark);
                    }
                    return _MessageBubble(
                      message: messages[index],
                      isDark: isDark,
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
                  child: Text(
                    'Error loading conversation: $e',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message bubble
// ---------------------------------------------------------------------------

class _MessageBubble extends StatefulWidget {
  final BridgeMessage message;
  final bool isDark;

  const _MessageBubble({required this.message, required this.isDark});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    // Collapse user (context) messages — they're verbose. Expand assistant.
    _isExpanded = !widget.message.isUser;
  }

  String _preview(String content) {
    if (content.isEmpty) return '';
    final first = content.split('\n').first;
    return first.length > 80 ? '${first.substring(0, 77)}…' : first;
  }

  bool _isLong(String content) =>
      content.length > 200 || content.split('\n').length > 3;

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.isUser;
    final text = widget.message.content;
    final toolCalls = widget.message.toolCalls;
    final hasLong = _isLong(text);
    final showCollapsed = isUser && hasLong && !_isExpanded;

    final bubbleColor = isUser
        ? (widget.isDark
            ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
            : BrandColors.driftwood.withValues(alpha: 0.1))
        : (widget.isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Role label
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: InkWell(
              onTap: hasLong ? () => setState(() => _isExpanded = !_isExpanded) : null,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isUser ? Icons.description_outlined : Icons.auto_fix_high,
                    size: 14,
                    color: isUser
                        ? (widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                        : BrandColors.turquoise,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isUser ? 'Context' : 'Bridge',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      fontWeight: FontWeight.w500,
                      color: isUser
                          ? (widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                          : BrandColors.turquoise,
                    ),
                  ),
                  if (isUser && hasLong) ...[
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

          // Bubble
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
                if (text.isNotEmpty)
                  showCollapsed
                      ? Text(
                          _preview(text),
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: widget.isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : SelectableText(
                          text,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodyMedium,
                            color: widget.isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                        ),
                if (widget.message.hasToolCalls) ...[
                  if (text.isNotEmpty) const SizedBox(height: Spacing.sm),
                  ...toolCalls.map((tool) => _ToolCallChip(tool: tool, isDark: widget.isDark)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tool call chip (expandable)
// ---------------------------------------------------------------------------

class _ToolCallChip extends StatefulWidget {
  final BridgeToolCall tool;
  final bool isDark;

  const _ToolCallChip({required this.tool, required this.isDark});

  @override
  State<_ToolCallChip> createState() => _ToolCallChipState();
}

class _ToolCallChipState extends State<_ToolCallChip> {
  bool _expanded = false;

  IconData _icon(String name) => switch (name) {
        'update_title' => Icons.title,
        'update_summary' => Icons.summarize,
        'log_activity' => Icons.note_add,
        _ => Icons.build,
      };

  @override
  Widget build(BuildContext context) {
    const toolColor = BrandColors.turquoise;
    final displayName = widget.tool.displayName;
    final hasInput = widget.tool.input.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasInput ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm, vertical: Spacing.xs),
              decoration: BoxDecoration(
                color: toolColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: toolColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon(displayName), size: 14, color: toolColor),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontWeight: FontWeight.w500,
                      color: toolColor,
                    ),
                  ),
                  if (hasInput) ...[
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
          if (_expanded && hasInput)
            Container(
              margin: const EdgeInsets.only(top: Spacing.xs),
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: widget.isDark ? BrandColors.nightSurface : BrandColors.softWhite,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: widget.isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.driftwood.withValues(alpha: 0.2),
                ),
              ),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(widget.tool.input),
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  fontFamily: 'monospace',
                  color: widget.isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Last run summary card (shown at the bottom of the conversation list)
// ---------------------------------------------------------------------------

class _LastRunCard extends StatelessWidget {
  final BridgeRun run;
  final bool isDark;

  const _LastRunCard({required this.run, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: BrandColors.turquoise.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, size: 14, color: BrandColors.turquoise),
              const SizedBox(width: Spacing.xs),
              Text(
                'Last run — Exchange #${run.exchangeNumber}',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w600,
                  color: BrandColors.turquoise,
                ),
              ),
              const Spacer(),
              Text(
                _formatTime(run.ts),
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),
          if (run.actions.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: run.actions.map((a) {
                final (icon, label, color) = switch (a) {
                  'update_title' => (
                      Icons.title,
                      run.newTitle != null ? 'Title → "${run.newTitle}"' : 'Title',
                      BrandColors.turquoise,
                    ),
                  'update_summary' => (Icons.summarize, 'Summary', BrandColors.forest),
                  'log_activity' => (Icons.note_add, 'Logged', BrandColors.warning),
                  _ => (Icons.build, a, BrandColors.driftwood),
                };
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm, vertical: Spacing.xxs),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: Spacing.xxs),
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            fontWeight: FontWeight.w500,
                            color: color,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                'No changes made',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m $amPm';
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? detail;
  final bool isDark;

  const _EmptyState({
    required this.icon,
    required this.message,
    this.detail,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                      .withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
