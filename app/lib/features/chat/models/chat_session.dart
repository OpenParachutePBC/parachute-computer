import 'curator_run.dart';

/// Source of a chat session
enum ChatSource {
  /// Native Parachute chat session
  parachute,

  /// Imported from ChatGPT
  chatgpt,

  /// Imported from Claude (web)
  claude,

  /// Bot connector: Telegram
  telegram,

  /// Bot connector: Discord
  discord,

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
      case ChatSource.telegram:
        return 'telegram';
      case ChatSource.discord:
        return 'discord';
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
      case ChatSource.telegram:
        return 'Telegram';
      case ChatSource.discord:
        return 'Discord';
      case ChatSource.other:
        return 'Imported';
    }
  }

  bool get isBotSession =>
      this == ChatSource.telegram || this == ChatSource.discord;

  static ChatSource fromString(String? value) {
    switch (value) {
      case 'chatgpt':
        return ChatSource.chatgpt;
      case 'claude':
        return ChatSource.claude;
      case 'telegram':
        return ChatSource.telegram;
      case 'discord':
        return ChatSource.discord;
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
  final String? agentType;
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

  /// Trust level for this session (full, vault, sandboxed)
  final String? trustLevel;

  /// Bot platform this session is linked to (telegram, discord)
  final String? linkedBotPlatform;

  /// Platform-specific chat ID
  final String? linkedBotChatId;

  /// Chat type on the platform (dm, group)
  final String? linkedBotChatType;

  /// Workspace slug this session belongs to
  final String? workspaceId;

  /// Additional metadata from the server (pending approval, pairing info, etc.)
  final Map<String, dynamic>? metadata;

  /// Whether this session is pending approval from the owner
  bool get isPendingApproval => metadata?['pending_approval'] == true;

  /// Whether this bot session needs initialization before it can respond
  bool get isPendingInitialization => metadata?['pending_initialization'] == true;

  /// Per-session response mode (all_messages or mention_only)
  String? get responseMode => (metadata?['bot_settings'] as Map?)?['response_mode'] as String?;

  /// Custom mention trigger pattern for mention_only mode
  String? get mentionPattern => (metadata?['bot_settings'] as Map?)?['mention_pattern'] as String?;

  /// The pairing request ID linked to this pending session
  String? get pairingRequestId => metadata?['pairing_request_id'] as String?;

  /// The first message sent by the unknown user
  String? get firstMessage => metadata?['first_message'] as String?;

  /// The most recent curator run result, if curator has run for this session
  CuratorRun? get curatorLastRun {
    final raw = metadata?['curator_last_run'];
    if (raw == null || raw is! Map<String, dynamic>) return null;
    return CuratorRun.fromJson(raw);
  }

  const ChatSession({
    required this.id,
    this.agentPath,
    this.agentName,
    this.agentType,
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
    this.trustLevel,
    this.linkedBotPlatform,
    this.linkedBotChatId,
    this.linkedBotChatType,
    this.workspaceId,
    this.metadata,
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
      agentType: json['agentType'] as String?,
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
      trustLevel: json['trustLevel'] as String? ?? json['trust_level'] as String?,
      linkedBotPlatform: json['linkedBotPlatform'] as String? ?? json['linked_bot_platform'] as String?,
      linkedBotChatId: json['linkedBotChatId'] as String? ?? json['linked_bot_chat_id'] as String?,
      linkedBotChatType: json['linkedBotChatType'] as String? ?? json['linked_bot_chat_type'] as String?,
      workspaceId: json['workspaceId'] as String? ?? json['workspace_id'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'agentPath': agentPath,
      'agentName': agentName,
      'agentType': agentType,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'messageCount': messageCount,
      'archived': archived,
      'source': source.name,
      if (continuedFrom != null) 'continuedFrom': continuedFrom,
      if (originalId != null) 'originalId': originalId,
      if (workingDirectory != null) 'workingDirectory': workingDirectory,
      if (trustLevel != null) 'trustLevel': trustLevel,
      if (linkedBotPlatform != null) 'linkedBotPlatform': linkedBotPlatform,
      if (linkedBotChatId != null) 'linkedBotChatId': linkedBotChatId,
      if (linkedBotChatType != null) 'linkedBotChatType': linkedBotChatType,
      if (workspaceId != null) 'workspaceId': workspaceId,
      if (metadata != null) 'metadata': metadata,
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

  /// Get the display name for the agent
  String? get agentDisplayName {
    if (agentName != null && agentName!.isNotEmpty) return agentName;
    if (agentType != null && agentType!.isNotEmpty) {
      // Convert agent type to display name (e.g., 'orchestrator' -> 'Orchestrator')
      return agentType!.split('-').map((word) =>
        word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : ''
      ).join(' ');
    }
    return null;
  }

  /// Whether this session uses a custom agent (not the default vault agent)
  bool get hasCustomAgent => agentType != null || agentPath != null || agentName != null;

  ChatSession copyWith({
    String? id,
    String? agentPath,
    String? agentName,
    String? agentType,
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
    String? trustLevel,
    String? linkedBotPlatform,
    String? linkedBotChatId,
    String? linkedBotChatType,
    String? workspaceId,
    Map<String, dynamic>? metadata,
  }) {
    return ChatSession(
      id: id ?? this.id,
      agentPath: agentPath ?? this.agentPath,
      agentName: agentName ?? this.agentName,
      agentType: agentType ?? this.agentType,
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
      trustLevel: trustLevel ?? this.trustLevel,
      linkedBotPlatform: linkedBotPlatform ?? this.linkedBotPlatform,
      linkedBotChatId: linkedBotChatId ?? this.linkedBotChatId,
      linkedBotChatType: linkedBotChatType ?? this.linkedBotChatType,
      workspaceId: workspaceId ?? this.workspaceId,
      metadata: metadata ?? this.metadata,
    );
  }
}
