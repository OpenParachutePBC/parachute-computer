import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/models/send_to_chat_event.dart';
import 'package:parachute/core/providers/app_events_provider.dart';

/// Available agent types for new chats
class AgentTypeOption {
  final String? id; // null = default vault agent
  final String? path; // path to agent definition file (e.g., 'Daily/.agents/orchestrator.md')
  final String label;
  final String description;
  final IconData icon;

  const AgentTypeOption({
    this.id,
    this.path,
    required this.label,
    required this.description,
    required this.icon,
  });
}

const _agentTypes = [
  AgentTypeOption(
    id: null,
    path: null,
    label: 'Default',
    description: 'Standard vault agent',
    icon: Icons.chat_bubble_outline,
  ),
  AgentTypeOption(
    id: 'orchestrator',
    path: 'Daily/.agents/orchestrator.md',
    label: 'Daily Orchestrator',
    description: 'Manages your day',
    icon: Icons.auto_awesome,
  ),
];

/// Bottom sheet for sending a journal entry to a chat session
class SendToChatSheet extends ConsumerStatefulWidget {
  final String content;
  final String? title;

  const SendToChatSheet({
    super.key,
    required this.content,
    this.title,
  });

  /// Show the send to chat sheet
  static Future<void> show(
    BuildContext context, {
    required String content,
    String? title,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SendToChatSheet(
        content: content,
        title: title,
      ),
    );
  }

  @override
  ConsumerState<SendToChatSheet> createState() => _SendToChatSheetState();
}

class _SendToChatSheetState extends ConsumerState<SendToChatSheet> {
  String? _selectedAgentType; // null = default

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
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
                Icon(
                  Icons.chat_bubble_outline,
                  color: isDark ? BrandColors.turquoise : BrandColors.turquoiseDeep,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  'Send to Chat',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleLarge,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ],
            ),
          ),

          // Preview of content being sent
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.title != null && widget.title!.isNotEmpty) ...[
                  Text(
                    widget.title!,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                ],
                Text(
                  widget.content.length > 150 ? '${widget.content.substring(0, 150)}...' : widget.content,
                  style: TextStyle(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    fontSize: 13,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          const SizedBox(height: Spacing.md),

          // New Chat section header
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'New Chat',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ),
          ),

          // Agent type selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: Row(
              children: _agentTypes.map((agent) {
                final isSelected = _selectedAgentType == agent.id;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: agent != _agentTypes.last ? Spacing.sm : 0,
                    ),
                    child: _buildAgentTypeChip(agent, isSelected, isDark),
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: Spacing.sm),

          // New Chat button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _sendToNewChat(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: Text(_selectedAgentType == null
                    ? 'New Chat'
                    : 'New ${_agentTypes.firstWhere((a) => a.id == _selectedAgentType).label}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: BrandColors.turquoise,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),


          // Bottom padding for safe area
          SizedBox(height: MediaQuery.of(context).padding.bottom + Spacing.md),
        ],
      ),
    );
  }

  Widget _buildAgentTypeChip(AgentTypeOption agent, bool isSelected, bool isDark) {
    return GestureDetector(
      onTap: () => setState(() => _selectedAgentType = agent.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? BrandColors.turquoise.withValues(alpha: 0.15)
              : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? BrandColors.turquoise : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              agent.icon,
              size: 16,
              color: isSelected
                  ? BrandColors.turquoise
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? BrandColors.turquoise
                          : (isDark ? BrandColors.nightText : BrandColors.charcoal),
                    ),
                  ),
                  Text(
                    agent.description,
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  void _sendToNewChat(BuildContext context, WidgetRef ref) {
    // Close the bottom sheet first
    Navigator.pop(context);

    // Get the selected agent's path
    final selectedAgent = _agentTypes.firstWhere(
      (a) => a.id == _selectedAgentType,
      orElse: () => _agentTypes.first,
    );

    // Emit send to chat event - Chat feature will handle it
    ref.read(sendToChatEventProvider.notifier).state = SendToChatEvent(
      content: widget.content,
      title: widget.title,
      sessionId: null, // new chat
      agentType: _selectedAgentType,
      agentPath: selectedAgent.path,
    );
  }
}
