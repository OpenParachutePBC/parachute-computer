import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/chat_session_actions.dart';
import '../providers/chat_session_providers.dart';
import '../screens/chat_screen.dart';

/// Chat content panel for use in adaptive layouts.
///
/// Shows ChatScreen when a session is selected or new chat mode is active,
/// or an empty state placeholder when idle.
class ChatContentPanel extends ConsumerWidget {
  const ChatContentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentSessionId = ref.watch(currentSessionIdProvider);
    final isNewChat = ref.watch(newChatModeProvider);

    if (currentSessionId == null && !isNewChat) {
      return _buildEmptyState(context);
    }

    return const ChatScreen(embeddedMode: true);
  }

  Widget _buildEmptyState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                : BrandColors.stone.withValues(alpha: 0.4),
          ),
          SizedBox(height: Spacing.md),
          Text(
            'Select a conversation',
            style: TextStyle(
              fontSize: TypographyTokens.titleMedium,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
          SizedBox(height: Spacing.xs),
          Text(
            'Or start a new chat from the sidebar',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                  : BrandColors.stone.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
