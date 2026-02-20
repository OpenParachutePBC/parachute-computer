import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_message.dart';
import 'user_question_card.dart';

/// Inline read-only question card rendered within a message bubble.
///
/// Shows the question with its status (pending, answered, timeout, dismissed).
/// For answered questions, highlights the selected answer(s).
/// For pending questions, shows a "Waiting for answer" indicator.
class InlineUserQuestionCard extends StatelessWidget {
  final UserQuestionData data;

  const InlineUserQuestionCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurface.withValues(alpha: 0.5)
              : BrandColors.cream.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: _borderColor(isDark),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with status badge
            _buildHeader(isDark),
            const SizedBox(height: Spacing.xs),
            // Questions with answers
            ...data.questions.map((q) => _buildQuestion(context, q, isDark)),
          ],
        ),
      ),
    );
  }

  Color _borderColor(bool isDark) {
    switch (data.status) {
      case UserQuestionStatus.answered:
        return isDark ? BrandColors.nightForest : BrandColors.forest;
      case UserQuestionStatus.pending:
        return isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
      case UserQuestionStatus.timeout:
      case UserQuestionStatus.dismissed:
        return isDark ? Colors.orange.shade700 : Colors.orange.shade300;
    }
  }

  Widget _buildHeader(bool isDark) {
    final IconData icon;
    final String label;
    final Color color;

    switch (data.status) {
      case UserQuestionStatus.answered:
        icon = Icons.check_circle_outline;
        label = 'Answered';
        color = isDark ? BrandColors.nightForest : BrandColors.forest;
      case UserQuestionStatus.pending:
        icon = Icons.help_outline;
        label = 'Waiting for answer';
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
      case UserQuestionStatus.timeout:
        icon = Icons.timer_off_outlined;
        label = 'Expired';
        color = isDark ? Colors.orange.shade300 : Colors.orange.shade700;
      case UserQuestionStatus.dismissed:
        icon = Icons.close;
        label = 'Dismissed';
        color = isDark ? Colors.orange.shade300 : Colors.orange.shade700;
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildQuestion(BuildContext context, Map<String, dynamic> questionJson, bool isDark) {
    final question = UserQuestion.fromJson(questionJson);
    final answerForQuestion = _getAnswerForQuestion(question.question);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Question text
          Text(
            question.question,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: 4),
          // Options as chips
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              ...question.options.map((option) {
                final isSelected = _isOptionSelected(question.question, option.label);
                return _buildChip(option.label, isSelected, isDark);
              }),
              // Show "Other" answer if it was a custom response
              if (answerForQuestion != null && _isCustomAnswer(question, answerForQuestion))
                _buildChip(
                  answerForQuestion is String ? answerForQuestion : answerForQuestion.toString(),
                  true,
                  isDark,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, bool isSelected, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isSelected
            ? (isDark ? BrandColors.nightForest.withValues(alpha: 0.3) : BrandColors.forestMist)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? (isDark ? BrandColors.nightForest : BrandColors.forest)
              : (isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.3) : BrandColors.driftwood.withValues(alpha: 0.3)),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected) ...[
            Icon(Icons.check, size: 12,
              color: isDark ? BrandColors.nightForest : BrandColors.forest),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected
                  ? (isDark ? BrandColors.nightText : BrandColors.charcoal)
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
            ),
          ),
        ],
      ),
    );
  }

  /// Get the answer for a specific question from the answers map
  dynamic _getAnswerForQuestion(String questionText) {
    if (data.answers == null) return null;
    return data.answers![questionText];
  }

  /// Check if a specific option label was selected in the answers
  bool _isOptionSelected(String questionText, String optionLabel) {
    final answer = _getAnswerForQuestion(questionText);
    if (answer == null) return false;
    if (answer is String) return answer == optionLabel;
    if (answer is List) return answer.contains(optionLabel);
    return false;
  }

  /// Check if the answer is a custom "Other" response (not matching any option)
  bool _isCustomAnswer(UserQuestion question, dynamic answer) {
    final optionLabels = question.options.map((o) => o.label).toSet();
    if (answer is String) return !optionLabels.contains(answer);
    if (answer is List) return answer.any((a) => !optionLabels.contains(a));
    return false;
  }
}
