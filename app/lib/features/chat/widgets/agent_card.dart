import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/agent.dart';

/// Card displaying an agent with type indicator
///
/// Shows different icons and colors based on agent type:
/// - Chatbot (default): Chat bubble, turquoise accent
/// - Standalone: Bolt icon, amber accent
/// - Doc: Document icon, forest accent
class AgentCard extends StatelessWidget {
  final Agent agent;
  final VoidCallback onTap;

  const AgentCard({
    super.key,
    required this.agent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final (icon, color, typeLabel) = _getAgentStyle();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.card,
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: isDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.softWhite,
            borderRadius: Radii.card,
            border: Border.all(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon with colored background
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.2 : 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 24,
                  color: color,
                ),
              ),

              const SizedBox(height: Spacing.sm),

              // Agent name
              Text(
                agent.name,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),

              const SizedBox(height: Spacing.xxs),

              // Type label
              Text(
                typeLabel,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  (IconData, Color, String) _getAgentStyle() {
    if (agent.isStandalone) {
      return (Icons.bolt, BrandColors.warning, 'Standalone');
    } else if (agent.isDocAgent) {
      return (Icons.description_outlined, BrandColors.forest, 'Document');
    } else {
      // Default chatbot
      return (Icons.chat_bubble_outline, BrandColors.turquoise, 'Chat');
    }
  }
}
