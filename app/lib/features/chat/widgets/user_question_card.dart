import 'package:flutter/material.dart';

/// Data class for a question from AskUserQuestion tool
class UserQuestion {
  final String question;
  final String header;
  final List<QuestionOption> options;
  final bool multiSelect;

  const UserQuestion({
    required this.question,
    required this.header,
    required this.options,
    this.multiSelect = false,
  });

  factory UserQuestion.fromJson(Map<String, dynamic> json) {
    final optionsList = (json['options'] as List<dynamic>?) ?? [];
    return UserQuestion(
      question: json['question'] as String? ?? '',
      header: json['header'] as String? ?? '',
      options: optionsList
          .map((o) => QuestionOption.fromJson(o as Map<String, dynamic>))
          .toList(),
      multiSelect: json['multiSelect'] as bool? ?? false,
    );
  }
}

/// A single option for a question
class QuestionOption {
  final String label;
  final String description;

  const QuestionOption({
    required this.label,
    required this.description,
  });

  factory QuestionOption.fromJson(Map<String, dynamic> json) {
    return QuestionOption(
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }
}

/// Card widget for displaying a user question from Claude
///
/// Shows question text with selectable options. When an option is selected,
/// calls [onAnswer] with the selected answer(s).
class UserQuestionCard extends StatefulWidget {
  final String requestId;
  final String sessionId;
  final List<UserQuestion> questions;
  final Future<bool> Function(Map<String, dynamic> answers) onAnswer;
  final bool isAnswered;

  const UserQuestionCard({
    super.key,
    required this.requestId,
    required this.sessionId,
    required this.questions,
    required this.onAnswer,
    this.isAnswered = false,
  });

  @override
  State<UserQuestionCard> createState() => _UserQuestionCardState();
}

class _UserQuestionCardState extends State<UserQuestionCard> {
  // Track selected answers per question
  final Map<String, Set<String>> _selectedAnswers = {};
  bool _isSubmitting = false;
  bool _isAnswered = false;

  @override
  void initState() {
    super.initState();
    _isAnswered = widget.isAnswered;
    // Initialize selection sets for each question
    for (final q in widget.questions) {
      _selectedAnswers[q.question] = {};
    }
  }

  void _toggleOption(UserQuestion question, String optionLabel) {
    if (_isAnswered || _isSubmitting) return;

    setState(() {
      final selected = _selectedAnswers[question.question]!;
      if (question.multiSelect) {
        // Multi-select: toggle the option
        if (selected.contains(optionLabel)) {
          selected.remove(optionLabel);
        } else {
          selected.add(optionLabel);
        }
      } else {
        // Single-select: replace selection
        selected.clear();
        selected.add(optionLabel);
      }
    });
  }

  bool get _canSubmit {
    if (_isAnswered || _isSubmitting) return false;
    // All questions must have at least one answer
    return widget.questions.every((q) {
      final selected = _selectedAnswers[q.question] ?? {};
      return selected.isNotEmpty;
    });
  }

  Future<void> _submitAnswers() async {
    if (!_canSubmit) return;

    setState(() => _isSubmitting = true);

    // Build answers map: question -> answer (string for single, list for multi)
    final answers = <String, dynamic>{};
    for (final q in widget.questions) {
      final selected = _selectedAnswers[q.question]!;
      if (q.multiSelect) {
        answers[q.question] = selected.toList();
      } else {
        answers[q.question] = selected.first;
      }
    }

    final success = await widget.onAnswer(answers);

    setState(() {
      _isSubmitting = false;
      if (success) {
        _isAnswered = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.help_outline,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Claude is asking...',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_isAnswered)
                  Chip(
                    label: const Text('Answered'),
                    backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
                    labelStyle: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Questions
            ...widget.questions.map((q) => _buildQuestion(context, q)),

            // Submit button
            if (!_isAnswered) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _canSubmit ? _submitAnswers : null,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, size: 18),
                  label: Text(_isSubmitting ? 'Sending...' : 'Submit Answer'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context, UserQuestion question) {
    final theme = Theme.of(context);
    final selected = _selectedAnswers[question.question] ?? {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Question text
        Text(
          question.question,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        if (question.multiSelect)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Select all that apply',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        const SizedBox(height: 8),

        // Options
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: question.options.map((option) {
            final isSelected = selected.contains(option.label);
            return _buildOptionChip(
              context,
              option,
              isSelected,
              () => _toggleOption(question, option.label),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildOptionChip(
    BuildContext context,
    QuestionOption option,
    bool isSelected,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Tooltip(
      message: option.description,
      child: FilterChip(
        label: Text(option.label),
        selected: isSelected,
        onSelected: (_isAnswered || _isSubmitting) ? null : (_) => onTap(),
        selectedColor: colorScheme.primaryContainer,
        checkmarkColor: colorScheme.primary,
        labelStyle: TextStyle(
          color: isSelected ? colorScheme.primary : colorScheme.onSurface,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
