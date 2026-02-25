/// A tool call made by the curator.
class CuratorToolCall {
  final String? id;
  final String name;
  final Map<String, dynamic> input;

  const CuratorToolCall({
    this.id,
    required this.name,
    this.input = const {},
  });

  factory CuratorToolCall.fromJson(Map<String, dynamic> json) {
    return CuratorToolCall(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'unknown',
      input: (json['input'] as Map<String, dynamic>?) ?? {},
    );
  }

  /// Display name with mcp__curator__ prefix stripped.
  String get displayName {
    if (name.startsWith('mcp__curator__')) {
      return name.substring('mcp__curator__'.length);
    }
    return name;
  }
}

/// A single message in the curator's conversation.
class CuratorMessage {
  final String role;
  final String content;
  final String? timestamp;
  final List<CuratorToolCall> toolCalls;

  const CuratorMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.toolCalls = const [],
  });

  factory CuratorMessage.fromJson(Map<String, dynamic> json) {
    return CuratorMessage(
      role: json['role'] as String,
      content: json['content'] as String? ?? '',
      timestamp: json['timestamp'] as String?,
      toolCalls: (json['tool_calls'] as List<dynamic>?)
              ?.map((e) => CuratorToolCall.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// The result of a curator background run, stored in session metadata.
///
/// The curator observes each chat exchange and decides what to update:
/// session title, summary, and activity log. This model captures what
/// happened on the most recent run, surfaced in the Flutter UI as a chip.
class CuratorRun {
  /// ISO-8601 timestamp of when the curator ran
  final DateTime ts;

  /// Exchange number this curator run observed
  final int exchangeNumber;

  /// MCP tool calls the curator made (e.g., ["update_title", "log_activity"])
  final List<String> actions;

  /// New title set by the curator, if update_title was called
  final String? newTitle;

  const CuratorRun({
    required this.ts,
    required this.exchangeNumber,
    required this.actions,
    this.newTitle,
  });

  factory CuratorRun.fromJson(Map<String, dynamic> json) {
    return CuratorRun(
      ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
      exchangeNumber: json['exchange_number'] as int? ?? 0,
      actions: (json['actions'] as List<dynamic>? ?? []).cast<String>(),
      newTitle: json['new_title'] as String?,
    );
  }

  /// Whether the curator made any changes on this run
  bool get hasChanges => actions.isNotEmpty;

  /// Human-readable summary of what the curator did
  String get summary {
    if (actions.isEmpty) return 'No changes';
    return actions.map((a) => switch (a) {
      'update_title' => 'Updated title',
      'update_summary' => 'Updated summary',
      'log_activity' => 'Logged',
      _ => a,
    }).join(' · ');
  }
}
