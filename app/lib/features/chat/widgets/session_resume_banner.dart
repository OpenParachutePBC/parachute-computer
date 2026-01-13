import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/session_resume_info.dart';

/// Banner showing session resume status
///
/// Displays information about how the session was resumed:
/// - SDK resume: Session was resumed natively (ideal)
/// - Context injection: Prior messages were re-injected (fallback)
/// - New: Fresh session with no prior context
///
/// Only shows prominently when SDK resume failed and fell back to context injection.
class SessionResumeBanner extends StatelessWidget {
  final SessionResumeInfo resumeInfo;
  final VoidCallback? onDismiss;

  const SessionResumeBanner({
    super.key,
    required this.resumeInfo,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Only show banner for context injection (especially if SDK failed)
    // SDK resume is ideal, new is expected - no need to show those
    if (resumeInfo.method == 'sdk_resume' || resumeInfo.method == 'new') {
      return const SizedBox.shrink();
    }

    // Context injection - show informational banner
    final showWarning = resumeInfo.sdkResumeFailed;

    // Warning color for dark/light mode
    final warningColor = isDark
        ? BrandColors.warning.withValues(alpha: 0.9)
        : BrandColors.warning;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: showWarning
            ? (isDark
                ? BrandColors.warning.withValues(alpha: 0.12)
                : BrandColors.warningLight.withValues(alpha: 0.5))
            : (isDark
                ? BrandColors.nightTurquoise.withValues(alpha: 0.1)
                : BrandColors.turquoiseMist.withValues(alpha: 0.5)),
        borderRadius: Radii.badge,
        border: Border.all(
          color: showWarning
              ? (isDark
                  ? BrandColors.warning.withValues(alpha: 0.3)
                  : BrandColors.warning.withValues(alpha: 0.3))
              : (isDark
                  ? BrandColors.nightTurquoise.withValues(alpha: 0.2)
                  : BrandColors.turquoise.withValues(alpha: 0.2)),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            showWarning ? Icons.refresh : Icons.history,
            size: 16,
            color: showWarning
                ? warningColor
                : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  showWarning ? 'Session context rebuilt' : 'Context loaded from history',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    fontWeight: FontWeight.w500,
                    color: showWarning
                        ? warningColor
                        : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep),
                  ),
                ),
                if (resumeInfo.messagesInjected > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${resumeInfo.messagesInjected} prior messages loaded (~${_formatTokens(resumeInfo.tokensEstimate)} tokens)',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall - 1,
                      color: showWarning
                          ? warningColor.withValues(alpha: 0.8)
                          : (isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onDismiss != null)
            GestureDetector(
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return tokens.toString();
  }
}

/// Compact chip showing session resume status (for app bar)
class SessionResumeChip extends StatelessWidget {
  final SessionResumeInfo resumeInfo;

  const SessionResumeChip({
    super.key,
    required this.resumeInfo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Don't show for new sessions
    if (resumeInfo.method == 'new') {
      return const SizedBox.shrink();
    }

    final isWarning = resumeInfo.sdkResumeFailed;
    final color = isWarning
        ? BrandColors.warning
        : (isDark ? BrandColors.nightForest : BrandColors.forest);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: Radii.badge,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isWarning ? Icons.refresh : Icons.check_circle_outline,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            resumeInfo.statusText,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall - 1,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
