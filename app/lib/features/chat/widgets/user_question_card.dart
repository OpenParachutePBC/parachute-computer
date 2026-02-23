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
