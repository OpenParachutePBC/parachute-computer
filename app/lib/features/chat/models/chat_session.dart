/// Source of a chat session
enum ChatSource {
  /// Native Parachute chat session
  parachute,

  /// Imported from ChatGPT
  chatgpt,

  /// Imported from Claude (web)
  claude,

  /// Imported from other source
  other,
}

/// Extension to parse ChatSource from string
extension ChatSourceExtension on ChatSource {
  String get name {
    switch (this) {
      case ChatSource.parachute:
        return 'parachute';
      case ChatSource.chatgpt:
        return 'chatgpt';
      case ChatSource.claude:
        return 'claude';
      case ChatSource.other:
        return 'other';
    }
  }

  String get displayName {
    switch (this) {
      case ChatSource.parachute:
        return 'Parachute';
      case ChatSource.chatgpt:
        return 'ChatGPT';
      case ChatSource.claude:
        return 'Claude';
      case ChatSource.other:
        return 'Imported';
    }
  }

  static ChatSource fromString(String? value) {
    switch (value) {
      case 'chatgpt':
        return ChatSource.chatgpt;
      case 'claude':
        return ChatSource.claude;
      case 'other':
        return ChatSource.other;
      case 'parachute':
      default:
        return ChatSource.parachute;
    }
  }
}

/// Represents a chat session with an AI agent
class ChatSession {
  final String id;
  final String? agentPath;
  final String? agentName;
  final String? title;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int messageCount;
  final bool archived;

  /// Whether this session was loaded from local files (vs from server API)
  final bool isLocal;

  /// Source of this session (parachute, chatgpt, claude, etc.)
  final ChatSource source;

  /// If this session continues another, the ID of the original session
  /// Used when continuing an imported conversation
  final String? continuedFrom;

  /// Original ID from the source system (for reference)
  /// e.g., ChatGPT conversation ID or Claude conversation ID
  final String? originalId;

  /// Working directory for this session (if different from vault)
  /// Allows operating on external codebases while storing sessions in vault
  final String? workingDirectory;

  const ChatSession({
    required this.id,
    this.agentPath,
    this.agentName,
    this.title,
    required this.createdAt,
    this.updatedAt,
    this.messageCount = 0,
    this.archived = false,
    this.isLocal = false,
    this.source = ChatSource.parachute,
    this.continuedFrom,
    this.originalId,
    this.workingDirectory,
  });

  /// Alias for archived (for consistency with local session reader)
  bool get isArchived => archived;

  /// Whether this is an imported session (not native Parachute)
  bool get isImported => source != ChatSource.parachute;

  /// Whether this session continues another conversation
  bool get isContinuation => continuedFrom != null;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    // Handle both 'updatedAt' and 'lastAccessed' field names from backend
    final updatedAtStr = json['updatedAt'] as String? ?? json['lastAccessed'] as String?;

    // SIMPLIFIED: The server now returns 'id' as the SDK session ID
    // This is the only session ID we need for all operations
    return ChatSession(
      id: json['id'] as String? ?? '',
      agentPath: json['agentPath'] as String?,
      agentName: json['agentName'] as String?,
      title: json['title'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      updatedAt: updatedAtStr != null ? DateTime.parse(updatedAtStr) : null,
      messageCount: json['messageCount'] as int? ?? 0,
      archived: json['archived'] as bool? ?? false,
      source: ChatSourceExtension.fromString(json['source'] as String?),
      continuedFrom: json['continuedFrom'] as String?,
      originalId: json['originalId'] as String?,
      workingDirectory: json['workingDirectory'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'agentPath': agentPath,
      'agentName': agentName,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'messageCount': messageCount,
      'archived': archived,
      'source': source.name,
      if (continuedFrom != null) 'continuedFrom': continuedFrom,
      if (originalId != null) 'originalId': originalId,
      if (workingDirectory != null) 'workingDirectory': workingDirectory,
    };
  }

  /// Whether this session operates on an external codebase
  bool get hasExternalWorkingDirectory => workingDirectory != null;

  /// Get just the directory name from the working directory path
  String? get workingDirectoryName {
    if (workingDirectory == null) return null;
    final parts = workingDirectory!.split('/');
    return parts.isNotEmpty ? parts.last : null;
  }

  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (agentName != null && agentName!.isNotEmpty) return 'Chat with $agentName';
    return 'New Chat';
  }

  ChatSession copyWith({
    String? id,
    String? agentPath,
    String? agentName,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? messageCount,
    bool? archived,
    bool? isLocal,
    ChatSource? source,
    String? continuedFrom,
    String? originalId,
    String? workingDirectory,
  }) {
    return ChatSession(
      id: id ?? this.id,
      agentPath: agentPath ?? this.agentPath,
      agentName: agentName ?? this.agentName,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageCount: messageCount ?? this.messageCount,
      archived: archived ?? this.archived,
      isLocal: isLocal ?? this.isLocal,
      source: source ?? this.source,
      continuedFrom: continuedFrom ?? this.continuedFrom,
      originalId: originalId ?? this.originalId,
      workingDirectory: workingDirectory ?? this.workingDirectory,
    );
  }
}
