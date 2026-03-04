/// An agent's output stored as a graph node (Card).
///
/// Replaces the vault-file-based [AgentOutput] model. Cards are fetched from
/// [DailyApiService.fetchCards] and stored in the Kuzu graph as Card nodes.
class AgentCard {
  /// Primary key: "{agent_name}:{date}" — deterministic, enables idempotent re-runs.
  final String cardId;
  final String agentName;
  final String displayName;

  /// Markdown body of the agent's output.
  final String content;

  /// "running" | "done" | "failed"
  final String status;

  /// ISO timestamp of when the card was last written.
  final String? generatedAt;

  /// YYYY-MM-DD (the day this card is for).
  final String date;

  const AgentCard({
    required this.cardId,
    required this.agentName,
    required this.displayName,
    required this.content,
    required this.status,
    this.generatedAt,
    required this.date,
  });

  factory AgentCard.fromJson(Map<String, dynamic> json) => AgentCard(
        cardId: json['card_id'] as String? ?? '',
        agentName: json['agent_name'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        content: json['content'] as String? ?? '',
        status: json['status'] as String? ?? 'done',
        generatedAt: json['generated_at'] as String?,
        date: json['date'] as String? ?? '',
      );

  bool get hasContent => content.trim().isNotEmpty;
  bool get isRunning => status == 'running';
  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
}
