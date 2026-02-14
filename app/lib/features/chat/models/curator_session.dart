/// Status of a curator task
enum CuratorTaskStatus {
  pending,
  running,
  completed,
  failed,
}

/// Extension to parse CuratorTaskStatus from string
extension CuratorTaskStatusExtension on CuratorTaskStatus {
  String get name {
    switch (this) {
      case CuratorTaskStatus.pending:
        return 'pending';
      case CuratorTaskStatus.running:
        return 'running';
      case CuratorTaskStatus.completed:
        return 'completed';
      case CuratorTaskStatus.failed:
        return 'failed';
    }
  }

  String get displayName {
    switch (this) {
      case CuratorTaskStatus.pending:
        return 'Pending';
      case CuratorTaskStatus.running:
        return 'Running';
      case CuratorTaskStatus.completed:
        return 'Completed';
      case CuratorTaskStatus.failed:
        return 'Failed';
    }
  }

  static CuratorTaskStatus fromString(String? value) {
    switch (value) {
      case 'running':
        return CuratorTaskStatus.running;
      case 'completed':
        return CuratorTaskStatus.completed;
      case 'failed':
        return CuratorTaskStatus.failed;
      case 'pending':
      default:
        return CuratorTaskStatus.pending;
    }
  }
}

/// Represents a curator session linked to a chat session.
///
/// The curator is a PERSISTENT SDK session that runs alongside each chat.
/// It maintains its own conversation history and can be viewed separately.
class CuratorSession {
  final String id;
  final String parentSessionId;
  final String? sdkSessionId;
  final DateTime? lastRunAt;
  final int lastMessageIndex;
  final DateTime createdAt;

  const CuratorSession({
    required this.id,
    required this.parentSessionId,
    this.sdkSessionId,
    this.lastRunAt,
    this.lastMessageIndex = 0,
    required this.createdAt,
  });

  factory CuratorSession.fromJson(Map<String, dynamic> json) {
    return CuratorSession(
      id: json['id'] as String,
      parentSessionId: json['parent_session_id'] as String,
      sdkSessionId: json['sdk_session_id'] as String?,
      lastRunAt: json['last_run_at'] != null
          ? DateTime.parse(json['last_run_at'] as String)
          : null,
      lastMessageIndex: json['last_message_index'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'parent_session_id': parentSessionId,
      'sdk_session_id': sdkSessionId,
      'last_run_at': lastRunAt?.toIso8601String(),
      'last_message_index': lastMessageIndex,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Whether this curator has an SDK session (has been run at least once)
  bool get hasSdkSession => sdkSessionId != null;
}

/// Result of a curator task execution
class CuratorTaskResult {
  final bool titleUpdated;
  final String? newTitle;
  final bool logged;
  final List<String> actions;
  final String? error;

  const CuratorTaskResult({
    this.titleUpdated = false,
    this.newTitle,
    this.logged = false,
    this.actions = const [],
    this.error,
  });

  factory CuratorTaskResult.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const CuratorTaskResult();
    }
    return CuratorTaskResult(
      titleUpdated: json['title_updated'] as bool? ?? false,
      newTitle: json['new_title'] as String?,
      logged: json['logged'] as bool? ?? false,
      actions: (json['actions'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      error: json['error'] as String?,
    );
  }

  /// Whether any updates were made
  bool get hasUpdates => titleUpdated || logged;

  /// Whether this task had no changes
  bool get noChanges => !titleUpdated && !logged && error == null;
}

/// Represents a queued curator task
class CuratorTask {
  final int id;
  final String? parentSessionId;
  final String? curatorSessionId;
  final String triggerType;
  final int messageCount;
  final DateTime queuedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final CuratorTaskStatus status;
  final CuratorTaskResult? result;
  final String? error;

  const CuratorTask({
    required this.id,
    this.parentSessionId,
    this.curatorSessionId,
    required this.triggerType,
    this.messageCount = 0,
    required this.queuedAt,
    this.startedAt,
    this.completedAt,
    required this.status,
    this.result,
    this.error,
  });

  factory CuratorTask.fromJson(Map<String, dynamic> json) {
    return CuratorTask(
      id: json['id'] as int,
      parentSessionId: json['parent_session_id'] as String?,
      curatorSessionId: json['curator_session_id'] as String?,
      triggerType: json['trigger_type'] as String? ?? 'unknown',
      messageCount: json['message_count'] as int? ?? 0,
      queuedAt: DateTime.parse(json['queued_at'] as String),
      startedAt: json['started_at'] != null
          ? DateTime.parse(json['started_at'] as String)
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      status: CuratorTaskStatusExtension.fromString(json['status'] as String?),
      result: json['result'] != null
          ? CuratorTaskResult.fromJson(json['result'] as Map<String, dynamic>)
          : null,
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'parent_session_id': parentSessionId,
      'curator_session_id': curatorSessionId,
      'trigger_type': triggerType,
      'message_count': messageCount,
      'queued_at': queuedAt.toIso8601String(),
      'started_at': startedAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'status': status.name,
      'result': result,
      'error': error,
    };
  }

  /// Duration of this task (if completed or running)
  Duration? get duration {
    if (startedAt == null) return null;
    final end = completedAt ?? DateTime.now();
    return end.difference(startedAt!);
  }

  /// Human-readable trigger type
  String get triggerTypeDisplay {
    switch (triggerType) {
      case 'message_done':
        return 'After message';
      case 'compact':
        return 'Session compact';
      case 'manual':
        return 'Manual trigger';
      default:
        return triggerType;
    }
  }
}

/// A single message in the curator's conversation
class CuratorMessage {
  final String role;
  final String content;
  final String? timestamp;
  final List<CuratorToolCall>? toolCalls;

  const CuratorMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.toolCalls,
  });

  factory CuratorMessage.fromJson(Map<String, dynamic> json) {
    return CuratorMessage(
      role: json['role'] as String,
      content: json['content'] as String? ?? '',
      timestamp: json['timestamp'] as String?,
      toolCalls: (json['tool_calls'] as List<dynamic>?)
          ?.map((e) => CuratorToolCall.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  DateTime? get parsedTimestamp =>
      timestamp != null ? DateTime.tryParse(timestamp!) : null;
}

/// A tool call made by the curator
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

  /// Get a user-friendly display name for the tool
  String get displayName {
    // Strip mcp__curator__ prefix if present
    if (name.startsWith('mcp__curator__')) {
      return name.substring('mcp__curator__'.length);
    }
    return name;
  }
}

/// Response containing curator messages (the curator's conversation history)
class CuratorMessages {
  final List<CuratorMessage> messages;
  final String? sdkSessionId;
  final int? messageCount;
  final String? errorMessage;

  const CuratorMessages({
    required this.messages,
    this.sdkSessionId,
    this.messageCount,
    this.errorMessage,
  });

  factory CuratorMessages.fromJson(Map<String, dynamic> json) {
    return CuratorMessages(
      messages: (json['messages'] as List<dynamic>?)
              ?.map((e) => CuratorMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      sdkSessionId: json['sdk_session_id'] as String?,
      messageCount: json['message_count'] as int?,
      errorMessage: json['message'] as String?,
    );
  }

  bool get hasMessages => messages.isNotEmpty;
  bool get hasSdkSession => sdkSessionId != null;
}

/// Combined response from the curator API
class CuratorInfo {
  final CuratorSession? curatorSession;
  final List<CuratorTask> recentTasks;

  const CuratorInfo({
    this.curatorSession,
    this.recentTasks = const [],
  });

  factory CuratorInfo.fromJson(Map<String, dynamic> json) {
    return CuratorInfo(
      curatorSession: json['curator_session'] != null
          ? CuratorSession.fromJson(
              json['curator_session'] as Map<String, dynamic>)
          : null,
      recentTasks: (json['recent_tasks'] as List<dynamic>?)
              ?.map((e) => CuratorTask.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Whether a curator exists for this session
  bool get hasCurator => curatorSession != null;

  /// Whether the curator has an SDK session (can view messages)
  bool get hasSdkSession => curatorSession?.hasSdkSession ?? false;

  /// Most recent task (if any)
  CuratorTask? get mostRecentTask =>
      recentTasks.isNotEmpty ? recentTasks.first : null;

  /// Count of completed tasks
  int get completedTaskCount =>
      recentTasks.where((t) => t.status == CuratorTaskStatus.completed).length;

  /// Count of tasks that made updates
  int get tasksWithUpdates =>
      recentTasks.where((t) => t.result?.hasUpdates ?? false).length;
}
