/// An agent's output stored as a graph node (Card).
///
/// Replaces the vault-file-based [AgentOutput] model. Cards are fetched from
/// [DailyApiService.fetchCards] and stored in the Kuzu graph as Card nodes.
class AgentCard {
  /// Primary key: "{agent_name}:{card_type}:{date}" — deterministic, enables idempotent re-runs.
  final String cardId;
  final String agentName;
  final String displayName;

  /// Card type — structural identity (e.g. "reflection", "weekly-review").
  /// Defaults to "default" for backward compatibility.
  final String cardType;

  /// Markdown body of the agent's output.
  final String content;

  /// "running" | "done" | "failed"
  final String status;

  /// ISO timestamp of when the card was last written.
  final String? generatedAt;

  /// YYYY-MM-DD (the day this card is for).
  final String date;

  /// ISO timestamp of when the card was read. Null/empty = unread.
  final String? readAt;

  const AgentCard({
    required this.cardId,
    required this.agentName,
    required this.displayName,
    this.cardType = 'default',
    required this.content,
    required this.status,
    this.generatedAt,
    required this.date,
    this.readAt,
  });

  factory AgentCard.fromJson(Map<String, dynamic> json) => AgentCard(
        cardId: json['card_id'] as String? ?? '',
        agentName: json['agent_name'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        cardType: (json['card_type'] as String?)?.isNotEmpty == true
            ? json['card_type'] as String
            : 'default',
        content: json['content'] as String? ?? '',
        status: json['status'] as String? ?? 'done',
        generatedAt: json['generated_at'] as String?,
        date: json['date'] as String? ?? '',
        readAt: json['read_at'] as String?,
      );

  bool get hasContent => content.trim().isNotEmpty;
  bool get isRunning => status == 'running';
  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';

  /// Whether the card has been read (read_at is set and non-empty).
  bool get isRead => readAt != null && readAt!.isNotEmpty;

  /// Whether the card is unread (read_at is null or empty).
  bool get isUnread => !isRead;

  /// Return a copy with read_at set (for optimistic local updates).
  AgentCard copyWithRead(String readAtTimestamp) => AgentCard(
        cardId: cardId,
        agentName: agentName,
        displayName: displayName,
        cardType: cardType,
        content: content,
        status: status,
        generatedAt: generatedAt,
        date: date,
        readAt: readAtTimestamp,
      );
}
