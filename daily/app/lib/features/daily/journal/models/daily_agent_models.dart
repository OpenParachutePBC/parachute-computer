/// Models for Daily agent management UI.
///
/// These mirror the server's Tool/AgentRun graph nodes and are used by
/// the agent management, detail, and log screens.

/// Memory mode for an agent — determines whether conversation history persists.
enum MemoryMode {
  persistent,
  fresh;

  static MemoryMode fromString(String? value) => switch (value) {
    'persistent' => MemoryMode.persistent,
    _ => MemoryMode.fresh,
  };
}

/// Parse a trigger filter from JSON (may be Map, String, or null).
Map<String, dynamic>? parseTriggerFilter(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.cast<String, dynamic>();
  return null;
}

/// A registered agent/tool on the server (graph Tool node).
class DailyAgentInfo {
  final String name;
  final String displayName;
  final String description;
  final String systemPrompt;
  final List<String> tools;
  final String trustLevel;
  final bool scheduleEnabled;
  final String scheduleTime;
  final String? lastRunAt;
  final String? lastProcessedDate;
  final int runCount;
  final String triggerEvent;
  final Map<String, dynamic>? triggerFilter;
  final MemoryMode memoryMode;
  final String? templateVersion;
  final bool userModified;
  final bool updateAvailable;
  final bool isBuiltin;
  final String containerSlug;

  const DailyAgentInfo({
    required this.name,
    required this.displayName,
    this.description = '',
    this.systemPrompt = '',
    this.tools = const [],
    this.trustLevel = 'sandboxed',
    this.scheduleEnabled = false,
    this.scheduleTime = '03:00',
    this.lastRunAt,
    this.lastProcessedDate,
    this.runCount = 0,
    this.triggerEvent = '',
    this.triggerFilter,
    this.memoryMode = MemoryMode.fresh,
    this.templateVersion,
    this.userModified = false,
    this.updateAvailable = false,
    this.isBuiltin = false,
    this.containerSlug = '',
  });

  /// Whether this agent is event-triggered (vs scheduled).
  bool get isTriggered => triggerEvent.isNotEmpty;
}

/// Starter template for creating a new agent.
class AgentTemplate {
  final String name;
  final String displayName;
  final String description;
  final String systemPrompt;
  final String memoryMode;
  final String? scheduleTime;
  final String? triggerEvent;

  const AgentTemplate({
    required this.name,
    required this.displayName,
    this.description = '',
    this.systemPrompt = '',
    this.memoryMode = 'fresh',
    this.scheduleTime,
    this.triggerEvent,
  });

  factory AgentTemplate.fromJson(Map<String, dynamic> json) {
    return AgentTemplate(
      name: json['name'] as String? ?? '',
      displayName: json['display_name'] as String? ?? json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      memoryMode: json['memory_mode'] as String? ?? 'fresh',
      scheduleTime: json['schedule_time'] as String?,
      triggerEvent: json['trigger_event'] as String?,
    );
  }
}

/// Result of triggering an agent run.
class AgentRunResult {
  final bool success;
  final String status;
  final String? error;
  final String? outputPath;

  const AgentRunResult({
    required this.success,
    required this.status,
    this.error,
    this.outputPath,
  });
}

/// Info about a specific agent run (AgentRun graph node).
class AgentRunInfo {
  final String id;
  final String agentName;
  final String status;
  final String? startedAt;
  final String? completedAt;
  final String? error;
  final String? trigger;

  const AgentRunInfo({
    required this.id,
    required this.agentName,
    required this.status,
    this.startedAt,
    this.completedAt,
    this.error,
    this.trigger,
  });

  bool get isFailed => status == 'failed';

  factory AgentRunInfo.fromJson(Map<String, dynamic> json) {
    return AgentRunInfo(
      id: json['id'] as String? ?? '',
      agentName: json['agent_name'] as String? ?? json['tool_name'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      startedAt: json['started_at'] as String?,
      completedAt: json['completed_at'] as String?,
      error: json['error'] as String?,
      trigger: json['trigger'] as String?,
    );
  }
}

/// Agent activity record for a journal entry.
class AgentActivity {
  final String agentName;
  final String displayName;
  final String status;
  final String? startedAt;
  final String? completedAt;
  final String? cardContent;

  const AgentActivity({
    required this.agentName,
    required this.displayName,
    required this.status,
    this.startedAt,
    this.completedAt,
    this.cardContent,
  });

  factory AgentActivity.fromJson(Map<String, dynamic> json) {
    return AgentActivity(
      agentName: json['agent_name'] as String? ?? json['tool_name'] as String? ?? '',
      displayName: json['display_name'] as String? ?? json['agent_name'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      startedAt: json['started_at'] as String?,
      completedAt: json['completed_at'] as String?,
      cardContent: json['card_content'] as String?,
    );
  }
}

/// A transcript from an agent's session.
class AgentTranscript {
  final String? sessionId;
  final String? message;
  final List<TranscriptMessage> messages;
  final int totalMessages;

  const AgentTranscript({
    this.sessionId,
    this.message,
    this.messages = const [],
    this.totalMessages = 0,
  });

  bool get hasTranscript => messages.isNotEmpty;

  factory AgentTranscript.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List<dynamic>? ?? [];
    final messages = rawMessages
        .map((m) => TranscriptMessage.fromJson(m as Map<String, dynamic>))
        .toList();
    return AgentTranscript(
      sessionId: json['session_id'] as String?,
      message: json['message'] as String?,
      messages: messages,
      totalMessages: (json['total_messages'] as num?)?.toInt() ?? messages.length,
    );
  }
}

/// A single message in an agent transcript.
class TranscriptMessage {
  final String role;
  final String? content;
  final List<TranscriptBlock>? blocks;

  const TranscriptMessage({
    required this.role,
    this.content,
    this.blocks,
  });

  bool get isAssistant => role == 'assistant';
  bool get isUser => role == 'user';

  factory TranscriptMessage.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['content'] as List<dynamic>?;
    String? textContent;
    List<TranscriptBlock>? blocks;

    if (rawBlocks != null && rawBlocks.isNotEmpty) {
      blocks = rawBlocks
          .whereType<Map<String, dynamic>>()
          .map(TranscriptBlock.fromJson)
          .toList();
      // Extract plain text content from text blocks
      final textParts = blocks
          .where((b) => b.isText && b.text != null)
          .map((b) => b.text!)
          .toList();
      if (textParts.isNotEmpty) textContent = textParts.join('\n');
    } else if (json['content'] is String) {
      textContent = json['content'] as String;
    }

    return TranscriptMessage(
      role: json['role'] as String? ?? 'unknown',
      content: textContent,
      blocks: blocks,
    );
  }
}

/// A content block within a transcript message (text, tool_use, tool_result).
class TranscriptBlock {
  final String type;
  final String? text;
  final String? name;
  final String? input;

  const TranscriptBlock({
    required this.type,
    this.text,
    this.name,
    this.input,
  });

  bool get isText => type == 'text';
  bool get isToolUse => type == 'tool_use';
  bool get isToolResult => type == 'tool_result';

  factory TranscriptBlock.fromJson(Map<String, dynamic> json) {
    String? inputStr;
    final rawInput = json['input'];
    if (rawInput is Map) {
      inputStr = rawInput.toString();
    } else if (rawInput is String) {
      inputStr = rawInput;
    }

    // For tool_result, content may be a list of blocks or a string
    String? text = json['text'] as String?;
    if (text == null && json['content'] is String) {
      text = json['content'] as String;
    } else if (text == null && json['content'] is List) {
      final parts = (json['content'] as List)
          .whereType<Map<String, dynamic>>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String?)
          .whereType<String>();
      if (parts.isNotEmpty) text = parts.join('\n');
    }

    return TranscriptBlock(
      type: json['type'] as String? ?? 'text',
      text: text,
      name: json['name'] as String?,
      input: inputStr,
    );
  }
}
