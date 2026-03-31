/// A tool call made by the bridge agent.
class BridgeToolCall {
  final String? id;
  final String name;
  final Map<String, dynamic> input;

  const BridgeToolCall({
    this.id,
    required this.name,
    this.input = const {},
  });

  factory BridgeToolCall.fromJson(Map<String, dynamic> json) {
    return BridgeToolCall(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'unknown',
      input: (json['input'] as Map<String, dynamic>?) ?? {},
    );
  }

  /// Display name with mcp__bridge__ prefix stripped.
  String get displayName {
    if (name.startsWith('mcp__bridge__')) {
      return name.substring('mcp__bridge__'.length);
    }
    return name;
  }
}

/// A single message in the bridge agent's conversation.
class BridgeMessage {
  final String role;
  final String content;
  final String? timestamp;
  final List<BridgeToolCall> toolCalls;

  const BridgeMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.toolCalls = const [],
  });

  factory BridgeMessage.fromJson(Map<String, dynamic> json) {
    return BridgeMessage(
      role: json['role'] as String,
      content: json['content'] as String? ?? '',
      timestamp: json['timestamp'] as String?,
      toolCalls: (json['tool_calls'] as List<dynamic>?)
              ?.map((e) => BridgeToolCall.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// The result of a bridge agent background run, stored in session metadata.
///
/// The bridge agent observes each chat exchange and decides what to update:
/// session title, summary, activity log, and brain facts. This model captures
/// what happened on the most recent run, surfaced in the Flutter UI as a chip.
class BridgeRun {
  /// ISO-8601 timestamp of when the bridge ran
  final DateTime ts;

  /// Exchange number this bridge run observed
  final int exchangeNumber;

  /// MCP tool calls the bridge made (e.g., ["update_title", "log_activity"])
  final List<String> actions;

  /// New title set by the bridge, if update_title was called
  final String? newTitle;

  const BridgeRun({
    required this.ts,
    required this.exchangeNumber,
    required this.actions,
    this.newTitle,
  });

  factory BridgeRun.fromJson(Map<String, dynamic> json) {
    return BridgeRun(
      ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
      exchangeNumber: json['exchange_number'] as int? ?? 0,
      actions: (json['actions'] as List<dynamic>? ?? []).cast<String>(),
      newTitle: json['new_title'] as String?,
    );
  }

  /// Whether the bridge made any changes on this run
  bool get hasChanges => actions.isNotEmpty;

  /// Human-readable summary of what the bridge did
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
