import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_message.dart';
import '../providers/chat_message_providers.dart';

/// Inline question card rendered within a message bubble.
///
/// When [data.status] is pending, renders interactive chips and a submit
/// button so the user can answer without the floating popup card.
/// For answered / timeout / dismissed states renders a read-only summary.
class InlineUserQuestionCard extends ConsumerStatefulWidget {
  final UserQuestionData data;

  const InlineUserQuestionCard({super.key, required this.data});

  @override
  ConsumerState<InlineUserQuestionCard> createState() =>
      _InlineUserQuestionCardState();
}

class _InlineUserQuestionCardState
    extends ConsumerState<InlineUserQuestionCard> {
  final Map<String, Set<String>> _selectedAnswers = {};
  final Map<String, TextEditingController> _otherControllers = {};
  final Map<String, bool> _otherSelected = {};
  bool _isSubmitting = false;
  bool _isAnswered = false; // locally answered — waiting for stream to confirm
  String? _errorMessage;
  late final List<UserQuestion> _questions;

  @override
  void initState() {
    super.initState();
    _questions = widget.data.questions
        .map((j) => UserQuestion.fromJson(j))
        .toList();
    if (widget.data.status == UserQuestionStatus.pending) {
      for (final q in _questions) {
        _selectedAnswers[q.question] = {};
        _otherControllers[q.question] = TextEditingController();
        _otherSelected[q.question] = false;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _otherControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(InlineUserQuestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset local state when the question status changes out of pending
    // (e.g., answered or timeout arrives via stream). This prevents stale
    // border colour / header icon when the same State instance is reused
    // by AutomaticKeepAliveClientMixin.
    if (oldWidget.data.status != widget.data.status &&
        widget.data.status != UserQuestionStatus.pending) {
      _isAnswered = false;
      _isSubmitting = false;
      _errorMessage = null;
    }
  }

  /// The card is interactable while the underlying data is pending and we
  /// haven't already submitted locally.
  bool get _isInteractive =>
      widget.data.status == UserQuestionStatus.pending && !_isAnswered && !_isSubmitting;

  void _toggleOption(UserQuestion question, String label) {
    if (!_isInteractive) return;
    setState(() {
      final selected = _selectedAnswers[question.question]!;
      if (question.multiSelect) {
        if (selected.contains(label)) {
          selected.remove(label);
        } else {
          selected.add(label);
        }
      } else {
        selected.clear();
        selected.add(label);
        _otherSelected[question.question] = false;
      }
    });
  }

  void _toggleOther(UserQuestion question) {
    if (!_isInteractive) return;
    setState(() {
      final isOther = !(_otherSelected[question.question] ?? false);
      _otherSelected[question.question] = isOther;
      if (!question.multiSelect) {
        _selectedAnswers[question.question]!.clear();
      }
    });
  }

  bool get _canSubmit {
    if (!_isInteractive) return false;
    return _questions.every((q) {
      final selected = _selectedAnswers[q.question] ?? {};
      final otherActive = _otherSelected[q.question] ?? false;
      final otherText = _otherControllers[q.question]?.text.trim() ?? '';
      if (otherActive) return otherText.isNotEmpty;
      return selected.isNotEmpty;
    });
  }

  Future<void> _submitAnswers() async {
    if (!_canSubmit) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final answers = <String, dynamic>{};
    for (final q in _questions) {
      final selected = _selectedAnswers[q.question]!;
      final otherActive = _otherSelected[q.question] ?? false;
      final otherText = _otherControllers[q.question]?.text.trim() ?? '';
      if (q.multiSelect) {
        final all = selected.toList();
        if (otherActive && otherText.isNotEmpty) all.add(otherText);
        answers[q.question] = all;
      } else {
        answers[q.question] =
            (otherActive && otherText.isNotEmpty) ? otherText : selected.first;
      }
    }

    final success =
        await ref.read(chatMessagesProvider.notifier).answerQuestion(answers);
    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
      if (success) {
        _isAnswered = true;
        _errorMessage = null;
      } else {
        _errorMessage = 'Failed to submit — tap to retry.';
      }
    });
  }

  Future<void> _dismissQuestion() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final success = await ref.read(chatMessagesProvider.notifier).answerQuestion({});
    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
      if (success) {
        _isAnswered = true;
      } else {
        _errorMessage = 'Failed to dismiss — tap to retry.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm, vertical: Spacing.xs),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurface.withValues(alpha: 0.5)
              : BrandColors.cream.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: _borderColor(isDark), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(isDark),
            const SizedBox(height: Spacing.xs),
            ..._questions
                .map((q) => _buildQuestion(context, q, isDark)),
            if (_errorMessage != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                _errorMessage!,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (_isInteractive || _isSubmitting) ...[
              const SizedBox(height: Spacing.xs),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      _canSubmit ? _submitAnswers : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                    minimumSize: const Size(0, 32),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Submit'),
                ),
              ),
              TextButton(
                onPressed: _isSubmitting ? null : _dismissQuestion,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('Skip'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _borderColor(bool isDark) {
    if (_isInteractive || _isSubmitting) {
      return isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
    }
    if (_isAnswered) {
      // Locally answered — show answered colour while stream confirms
      return isDark ? BrandColors.nightForest : BrandColors.forest;
    }
    switch (widget.data.status) {
      case UserQuestionStatus.answered:
        return isDark ? BrandColors.nightForest : BrandColors.forest;
      case UserQuestionStatus.pending:
        return isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
      case UserQuestionStatus.timeout:
        return isDark ? Colors.orange.shade700 : Colors.orange.shade300;
    }
  }

  Widget _buildHeader(bool isDark) {
    final IconData icon;
    final String label;
    final Color color;

    if (_isAnswered) {
      icon = Icons.check_circle_outline;
      label = 'Answered';
      color = isDark ? BrandColors.nightForest : BrandColors.forest;
    } else {
      switch (widget.data.status) {
        case UserQuestionStatus.answered:
          icon = Icons.check_circle_outline;
          label = 'Answered';
          color = isDark ? BrandColors.nightForest : BrandColors.forest;
        case UserQuestionStatus.pending:
          icon = Icons.help_outline;
          label = 'Question for you';
          color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
        case UserQuestionStatus.timeout:
          icon = Icons.timer_off_outlined;
          label = 'Expired';
          color = isDark ? Colors.orange.shade300 : Colors.orange.shade700;
      }
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: Spacing.xs),
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

  Widget _buildQuestion(
      BuildContext context, UserQuestion question, bool isDark) {
    final selected = _selectedAnswers[question.question] ?? {};
    final otherActive = _otherSelected[question.question] ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question.question,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              ...question.options.map((option) {
                if (_isInteractive) {
                  final isSelected = selected.contains(option.label);
                  return _buildInteractiveChip(
                    context,
                    option.label,
                    isSelected,
                    tooltip: option.description.isNotEmpty
                        ? option.description
                        : null,
                    onTap: () => _toggleOption(question, option.label),
                  );
                } else {
                  final isSelected =
                      _isOptionSelected(question.question, option.label);
                  return _buildReadOnlyChip(option.label, isSelected, isDark);
                }
              }),
              // "Other" chip — interactive mode only
              if (_isInteractive)
                _buildInteractiveChip(
                  context,
                  'Other',
                  otherActive,
                  onTap: () => _toggleOther(question),
                ),
              // Show custom answer as chip in read-only mode
              if (!_isInteractive) ...() {
                final ans = _getAnswerForQuestion(question.question);
                if (ans != null && _isCustomAnswer(question, ans)) {
                  return [
                    _buildReadOnlyChip(
                      ans is String ? ans : ans.toString(),
                      true,
                      isDark,
                    )
                  ];
                }
                return <Widget>[];
              }(),
            ],
          ),
          if (_isInteractive && otherActive) ...[
            const SizedBox(height: Spacing.xs),
            TextField(
              controller: _otherControllers[question.question],
              enabled: !_isSubmitting,
              decoration: InputDecoration(
                hintText: 'Type your answer...',
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.sm)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md, vertical: Spacing.sm),
              ),
              style: const TextStyle(fontSize: 13),
              maxLines: 3,
              maxLength: 500,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInteractiveChip(
    BuildContext context,
    String label,
    bool isSelected, {
    String? tooltip,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final chip = FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: isSelected,
      onSelected: _isSubmitting ? null : (_) => onTap(),
      selectedColor: theme.colorScheme.primaryContainer,
      checkmarkColor: theme.colorScheme.primary,
      labelStyle: TextStyle(
        color: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 12,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    if (tooltip != null && tooltip.isNotEmpty) {
      return Tooltip(message: tooltip, child: chip);
    }
    return chip;
  }

  Widget _buildReadOnlyChip(String label, bool isSelected, bool isDark) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xxs),
      decoration: BoxDecoration(
        color: isSelected
            ? (isDark
                ? BrandColors.nightForest.withValues(alpha: 0.3)
                : BrandColors.forestMist)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isSelected
              ? (isDark ? BrandColors.nightForest : BrandColors.forest)
              : (isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
                  : BrandColors.driftwood.withValues(alpha: 0.3)),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected) ...[
            Icon(Icons.check,
                size: 12,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            const SizedBox(width: Spacing.xxs),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected
                  ? (isDark ? BrandColors.nightText : BrandColors.charcoal)
                  : (isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood),
            ),
          ),
        ],
      ),
    );
  }

  dynamic _getAnswerForQuestion(String questionText) {
    if (widget.data.answers == null) return null;
    return widget.data.answers![questionText];
  }

  bool _isOptionSelected(String questionText, String optionLabel) {
    final answer = _getAnswerForQuestion(questionText);
    if (answer == null) return false;
    if (answer is String) return answer == optionLabel;
    if (answer is List) return answer.contains(optionLabel);
    return false;
  }

  bool _isCustomAnswer(UserQuestion question, dynamic answer) {
    final labels = question.options.map((o) => o.label).toSet();
    if (answer is String) return !labels.contains(answer);
    if (answer is List) return answer.any((a) => !labels.contains(a));
    return false;
  }
}
