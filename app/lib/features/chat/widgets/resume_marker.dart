import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'message_bubble.dart';

/// Marker showing that this conversation continues from a previous session
///
/// Shows prior messages as regular chat bubbles with a divider indicating
/// where the new conversation picks up.
class ResumeMarker extends StatelessWidget {
  /// The original session this continues from
  final ChatSession originalSession;

  /// Messages from the original session
  final List<ChatMessage> priorMessages;

  const ResumeMarker({
    super.key,
    required this.originalSession,
    required this.priorMessages,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        // Prior messages header
        _buildHeader(isDark),

        // Prior messages as regular chat bubbles
        ...priorMessages.map((msg) => MessageBubble(message: msg)),

        // Divider between prior and new messages
        _buildDivider(isDark),
      ],
    );
  }

  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Text(
              'Previous conversation',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: isDark
                  ? BrandColors.nightForest.withValues(alpha: 0.3)
                  : BrandColors.forest.withValues(alpha: 0.3),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightForest.withValues(alpha: 0.15)
                  : BrandColors.forestMist.withValues(alpha: 0.5),
              borderRadius: Radii.pill,
              border: Border.all(
                color: isDark
                    ? BrandColors.nightForest.withValues(alpha: 0.3)
                    : BrandColors.forest.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history,
                  size: 14,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  '${priorMessages.length} prior messages',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: isDark
                  ? BrandColors.nightForest.withValues(alpha: 0.3)
                  : BrandColors.forest.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
