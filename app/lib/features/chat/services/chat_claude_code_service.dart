part of 'chat_service.dart';

/// Extension for Claude Code session import operations
extension ChatClaudeCodeService on ChatService {
  /// Get recent Claude Code sessions across all projects
  /// This is the primary method for the flat-list UI
  Future<List<ClaudeCodeSession>> getRecentClaudeCodeSessions({int limit = 100}) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/claude-code/recent?limit=$limit'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60)); // Can be slow scanning many projects

      if (response.statusCode != 200) {
        throw Exception('Failed to get recent Claude Code sessions: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final sessionsList = decoded['sessions'] as List<dynamic>? ?? [];

      return sessionsList
          .map((s) => ClaudeCodeSession.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error getting recent Claude Code sessions: $e');
      rethrow;
    }
  }

  /// Get list of Claude Code projects (working directories)
  Future<List<ClaudeCodeProject>> getClaudeCodeProjects() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/claude-code/projects'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get Claude Code projects: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final projectsList = decoded['projects'] as List<dynamic>? ?? [];

      return projectsList
          .map((p) => ClaudeCodeProject.fromJson(p as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error getting Claude Code projects: $e');
      rethrow;
    }
  }

  /// Get sessions for a specific Claude Code project
  Future<List<ClaudeCodeSession>> getClaudeCodeSessions(String projectPath) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/claude-code/sessions?path=${Uri.encodeComponent(projectPath)}'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60)); // Can be slow for large projects

      if (response.statusCode != 200) {
        throw Exception('Failed to get Claude Code sessions: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      final sessionsList = decoded['sessions'] as List<dynamic>? ?? [];

      return sessionsList
          .map((s) => ClaudeCodeSession.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error getting Claude Code sessions: $e');
      rethrow;
    }
  }

  /// Get full details for a Claude Code session
  Future<ClaudeCodeSessionDetails> getClaudeCodeSessionDetails(
    String sessionId, {
    String? projectPath,
  }) async {
    try {
      final uri = projectPath != null
          ? Uri.parse('$baseUrl/api/claude-code/sessions/$sessionId?path=${Uri.encodeComponent(projectPath)}')
          : Uri.parse('$baseUrl/api/claude-code/sessions/$sessionId');

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 404) {
        throw Exception('Session not found');
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get session details: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      return ClaudeCodeSessionDetails.fromJson(decoded as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ChatService] Error getting Claude Code session details: $e');
      rethrow;
    }
  }

  /// Adopt a Claude Code session into Parachute
  Future<ClaudeCodeAdoptResult> adoptClaudeCodeSession(
    String sessionId, {
    String? projectPath,
    String? workingDirectory,
  }) async {
    try {
      final uri = projectPath != null
          ? Uri.parse('$baseUrl/api/claude-code/adopt/$sessionId?path=${Uri.encodeComponent(projectPath)}')
          : Uri.parse('$baseUrl/api/claude-code/adopt/$sessionId');

      final response = await client.post(
        uri,
        headers: defaultHeaders,
        body: workingDirectory != null
            ? jsonEncode({'workingDirectory': workingDirectory})
            : null,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('Failed to adopt session: ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      return ClaudeCodeAdoptResult.fromJson(decoded as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ChatService] Error adopting Claude Code session: $e');
      rethrow;
    }
  }
}

/// A Claude Code project (working directory)
class ClaudeCodeProject {
  final String encodedName;
  final String path;
  final int sessionCount;

  const ClaudeCodeProject({
    required this.encodedName,
    required this.path,
    required this.sessionCount,
  });

  factory ClaudeCodeProject.fromJson(Map<String, dynamic> json) {
    return ClaudeCodeProject(
      encodedName: json['encodedName'] as String? ?? '',
      path: json['path'] as String? ?? '',
      sessionCount: json['sessionCount'] as int? ?? 0,
    );
  }

  /// Get a short display name (last 2-3 path components)
  String get displayName {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 3) return parts.join('/');
    return '.../${parts.sublist(parts.length - 3).join('/')}';
  }
}

/// A Claude Code session summary
class ClaudeCodeSession {
  final String sessionId;
  final String? title;
  final String? firstMessage;
  final int messageCount;
  final DateTime? createdAt;
  final DateTime? lastTimestamp;
  final String? model;
  final String? cwd;
  final String? projectPath; // Full project path (from /recent endpoint)
  final String? projectDisplayName; // Short display name (from /recent endpoint)

  const ClaudeCodeSession({
    required this.sessionId,
    this.title,
    this.firstMessage,
    required this.messageCount,
    this.createdAt,
    this.lastTimestamp,
    this.model,
    this.cwd,
    this.projectPath,
    this.projectDisplayName,
  });

  factory ClaudeCodeSession.fromJson(Map<String, dynamic> json) {
    return ClaudeCodeSession(
      sessionId: json['sessionId'] as String? ?? '',
      title: json['title'] as String?,
      firstMessage: json['firstMessage'] as String?,
      messageCount: json['messageCount'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      lastTimestamp: json['lastTimestamp'] != null
          ? DateTime.tryParse(json['lastTimestamp'] as String)
          : null,
      model: json['model'] as String?,
      cwd: json['cwd'] as String?,
      projectPath: json['projectPath'] as String?,
      projectDisplayName: json['projectDisplayName'] as String?,
    );
  }

  /// Display title - uses title, first message preview, or session ID
  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (firstMessage != null && firstMessage!.isNotEmpty) {
      final preview = firstMessage!.length > 60
          ? '${firstMessage!.substring(0, 60)}...'
          : firstMessage!;
      return preview;
    }
    return 'Session ${sessionId.substring(0, 8)}';
  }

  /// Short model name (e.g., "opus" from "claude-opus-4-5-20251101")
  String? get shortModelName {
    if (model == null) return null;
    if (model!.contains('opus')) return 'Opus';
    if (model!.contains('sonnet')) return 'Sonnet';
    if (model!.contains('haiku')) return 'Haiku';
    return model;
  }
}

/// Full Claude Code session details including messages
class ClaudeCodeSessionDetails {
  final String sessionId;
  final String? title;
  final String? cwd;
  final String? model;
  final DateTime? createdAt;
  final List<ClaudeCodeMessage> messages;

  const ClaudeCodeSessionDetails({
    required this.sessionId,
    this.title,
    this.cwd,
    this.model,
    this.createdAt,
    required this.messages,
  });

  factory ClaudeCodeSessionDetails.fromJson(Map<String, dynamic> json) {
    final messagesList = json['messages'] as List<dynamic>? ?? [];
    return ClaudeCodeSessionDetails(
      sessionId: json['sessionId'] as String? ?? '',
      title: json['title'] as String?,
      cwd: json['cwd'] as String?,
      model: json['model'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      messages: messagesList
          .map((m) => ClaudeCodeMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// A message from a Claude Code session
class ClaudeCodeMessage {
  final String type; // 'user' or 'assistant'
  final String? content;
  final DateTime? timestamp;

  const ClaudeCodeMessage({
    required this.type,
    this.content,
    this.timestamp,
  });

  factory ClaudeCodeMessage.fromJson(Map<String, dynamic> json) {
    return ClaudeCodeMessage(
      type: json['type'] as String? ?? 'unknown',
      content: json['content'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String)
          : null,
    );
  }

  bool get isUser => type == 'user';
  bool get isAssistant => type == 'assistant';
}

/// Result of adopting a Claude Code session
class ClaudeCodeAdoptResult {
  final bool success;
  final bool alreadyAdopted;
  final String parachuteSessionId;
  final String? filePath;
  final int? messageCount;
  final String message;

  const ClaudeCodeAdoptResult({
    required this.success,
    this.alreadyAdopted = false,
    required this.parachuteSessionId,
    this.filePath,
    this.messageCount,
    required this.message,
  });

  factory ClaudeCodeAdoptResult.fromJson(Map<String, dynamic> json) {
    return ClaudeCodeAdoptResult(
      success: json['success'] as bool? ?? false,
      alreadyAdopted: json['alreadyAdopted'] as bool? ?? false,
      parachuteSessionId: json['parachuteSessionId'] as String? ?? '',
      filePath: json['filePath'] as String?,
      messageCount: json['messageCount'] as int?,
      message: json['message'] as String? ?? '',
    );
  }
}
