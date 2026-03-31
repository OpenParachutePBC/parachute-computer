import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_log.dart';
import 'chat_log_entry_card.dart';

/// Widget displaying chat log entries for a day
class ChatLogSection extends StatelessWidget {
  final ChatLog chatLog;
  final VoidCallback? onRefresh;

  const ChatLogSection({
    super.key,
    required this.chatLog,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (chatLog.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 18,
                color: BrandColors.turquoise,
              ),
              const SizedBox(width: 8),
              Text(
                'AI Conversations',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${chatLog.entries.length} session${chatLog.entries.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),

        // Entries - use shared card widget
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: chatLog.entries
                .map((entry) => ChatLogEntryCard(entry: entry, useDeepLinks: false))
                .toList(),
          ),
        ),

        const SizedBox(height: 8),
      ],
    );
  }
}
