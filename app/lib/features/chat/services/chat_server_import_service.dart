part of 'chat_service.dart';

/// Extension for import and transcript operations
extension ChatImportService on ChatService {
  /// Import conversations from Claude or ChatGPT exports
  ///
  /// Sends the parsed JSON to the server which:
  /// 1. Converts conversations to SDK JSONL format
  /// 2. Writes JSONL files to ~/.claude/projects/
  /// 3. Creates session records in SQLite
  ///
  /// Returns import result with counts and session IDs.
  Future<ImportResult> importConversations(
    dynamic jsonData, {
    bool archived = true,
  }) async {
    try {
      debugPrint('[ChatService] Starting import...');
      final response = await client.post(
        Uri.parse('$baseUrl/api/import'),
        headers: defaultHeaders,
        body: jsonEncode({
          'data': jsonData,
          'archived': archived,
        }),
      ).timeout(const Duration(minutes: 5)); // Imports can take a while

      if (response.statusCode != 200) {
        final error = response.body;
        throw Exception('Import failed: $error');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[ChatService] Import complete: ${data['imported_count']} imported');
      return ImportResult.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error importing: $e');
      rethrow;
    }
  }

  /// Curate a Claude export using the smart Import Curator
  ///
  /// This calls the server-side curator which intelligently parses
  /// memories.json and projects.json to create structured context files
  /// in the Parachute-native format with Facts, Focus, and History sections.
  ///
  /// Returns a result with lists of files created/updated.
  Future<CurateExportResult> curateClaudeExport(String exportPath) async {
    try {
      debugPrint('[ChatService] Curating Claude export at: $exportPath');
      final response = await client.post(
        Uri.parse('$baseUrl/api/import/curate'),
        headers: defaultHeaders,
        body: jsonEncode({'export_path': exportPath}),
      ).timeout(const Duration(minutes: 2));

      if (response.statusCode != 200) {
        final error = response.body;
        throw Exception('Curation failed: $error');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[ChatService] Curation complete: ${data['context_files_created']}');
      return CurateExportResult.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error curating export: $e');
      rethrow;
    }
  }

  /// Get context files with metadata
  ///
  /// Returns structured info about each context file including
  /// fact counts, history entries, and last modified time.
  Future<ContextFilesInfo> getContextFilesInfo() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/import/contexts'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get context files: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ContextFilesInfo.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting context files: $e');
      rethrow;
    }
  }

  /// Get recent curator activity
  ///
  /// Returns recent context file updates and title changes
  /// to show users what the curator has been learning.
  Future<CuratorActivityInfo> getRecentCuratorActivity({int limit = 10}) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/curator/activity/recent?limit=$limit'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get curator activity: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return CuratorActivityInfo.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting curator activity: $e');
      rethrow;
    }
  }

  /// Get the full SDK transcript for a session
  ///
  /// Returns rich event history including tool calls, thinking blocks, etc.
  /// This is more detailed than the markdown-based messages.
  ///
  /// [afterCompact] - Only return events after the last compact boundary (default: true)
  ///   This is faster for initial load since compacted history is usually summarized.
  /// [segment] - Load a specific segment by index (0-based, 0 = oldest)
  ///   Use this to lazy-load older segments on demand.
  /// [full] - Load all events (overrides afterCompact and segment)
  ///   Use for export, full search, etc.
  Future<SessionTranscript?> getSessionTranscript(
    String sessionId, {
    bool afterCompact = true,
    int? segment,
    bool full = false,
  }) async {
    try {
      // Build query parameters
      final queryParams = <String, String>{
        'after_compact': afterCompact.toString(),
      };
      if (segment != null) {
        queryParams['segment'] = segment.toString();
      }
      if (full) {
        queryParams['full'] = 'true';
      }

      final uri = Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/transcript')
          .replace(queryParameters: queryParams);

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60)); // Transcripts can be large

      if (response.statusCode == 404) {
        debugPrint('[ChatService] No transcript available for session $sessionId');
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get transcript: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return SessionTranscript.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting transcript: $e');
      return null; // Don't rethrow - transcript is optional enhancement
    }
  }
}

/// Result of importing conversations via the API
class ImportResult {
  final int totalConversations;
  final int importedCount;
  final int skippedCount;
  final List<String> errors;
  final List<String> sessionIds;

  const ImportResult({
    required this.totalConversations,
    required this.importedCount,
    required this.skippedCount,
    required this.errors,
    required this.sessionIds,
  });

  factory ImportResult.fromJson(Map<String, dynamic> json) {
    return ImportResult(
      totalConversations: json['total_conversations'] as int? ?? 0,
      importedCount: json['imported_count'] as int? ?? 0,
      skippedCount: json['skipped_count'] as int? ?? 0,
      errors: (json['errors'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      sessionIds: (json['session_ids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  bool get hasErrors => errors.isNotEmpty;
  bool get isSuccess => importedCount > 0;
}

/// Result of curating a Claude export with the Import Curator
class CurateExportResult {
  final bool success;
  final List<String> contextFilesCreated;
  final List<String> contextFilesUpdated;
  final String? generalContextSummary;
  final List<Map<String, dynamic>> projectContexts;
  final String? error;

  const CurateExportResult({
    required this.success,
    required this.contextFilesCreated,
    required this.contextFilesUpdated,
    this.generalContextSummary,
    this.projectContexts = const [],
    this.error,
  });

  factory CurateExportResult.fromJson(Map<String, dynamic> json) {
    return CurateExportResult(
      success: json['success'] as bool? ?? false,
      contextFilesCreated: (json['context_files_created'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      contextFilesUpdated: (json['context_files_updated'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      generalContextSummary: json['general_context_summary'] as String?,
      projectContexts: (json['project_contexts'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>)
              .toList() ??
          [],
      error: json['error'] as String?,
    );
  }

  int get totalFilesAffected =>
      contextFilesCreated.length + contextFilesUpdated.length;
}

/// Information about context files from the server
class ContextFilesInfo {
  final List<ContextFileMetadata> files;
  final int totalFacts;
  final int totalHistoryEntries;

  const ContextFilesInfo({
    required this.files,
    required this.totalFacts,
    required this.totalHistoryEntries,
  });

  factory ContextFilesInfo.fromJson(Map<String, dynamic> json) {
    return ContextFilesInfo(
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => ContextFileMetadata.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      totalFacts: json['total_facts'] as int? ?? 0,
      totalHistoryEntries: json['total_history_entries'] as int? ?? 0,
    );
  }
}

/// Metadata about a single context file
class ContextFileMetadata {
  final String path;
  final String name;
  final String description;
  final int factsCount;
  final int focusCount;
  final int historyCount;
  final bool isNativeFormat;
  final DateTime? lastModified;

  const ContextFileMetadata({
    required this.path,
    required this.name,
    this.description = '',
    this.factsCount = 0,
    this.focusCount = 0,
    this.historyCount = 0,
    this.isNativeFormat = false,
    this.lastModified,
  });

  factory ContextFileMetadata.fromJson(Map<String, dynamic> json) {
    return ContextFileMetadata(
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      factsCount: json['facts_count'] as int? ?? 0,
      focusCount: json['focus_count'] as int? ?? 0,
      historyCount: json['history_count'] as int? ?? 0,
      isNativeFormat: json['is_native_format'] as bool? ?? false,
      lastModified: json['last_modified'] != null
          ? DateTime.tryParse(json['last_modified'] as String)
          : null,
    );
  }
}

/// Information about recent curator activity
class CuratorActivityInfo {
  final List<CuratorUpdate> recentUpdates;
  final List<String> contextFilesModified;
  final DateTime? lastActivityAt;

  const CuratorActivityInfo({
    required this.recentUpdates,
    required this.contextFilesModified,
    this.lastActivityAt,
  });

  factory CuratorActivityInfo.fromJson(Map<String, dynamic> json) {
    return CuratorActivityInfo(
      recentUpdates: (json['recent_updates'] as List<dynamic>?)
              ?.map((e) => CuratorUpdate.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      contextFilesModified: (json['context_files_modified'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      lastActivityAt: json['last_activity_at'] != null
          ? DateTime.tryParse(json['last_activity_at'] as String)
          : null,
    );
  }

  bool get hasRecentActivity => recentUpdates.isNotEmpty;
}

/// A single curator update record
class CuratorUpdate {
  final int taskId;
  final String sessionId;
  final DateTime completedAt;
  final List<String> actions;
  final String? reasoning;
  final String? newTitle;

  const CuratorUpdate({
    required this.taskId,
    required this.sessionId,
    required this.completedAt,
    required this.actions,
    this.reasoning,
    this.newTitle,
  });

  factory CuratorUpdate.fromJson(Map<String, dynamic> json) {
    return CuratorUpdate(
      taskId: json['task_id'] as int? ?? 0,
      sessionId: json['session_id'] as String? ?? '',
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? '') ??
          DateTime.now(),
      actions: (json['actions'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      reasoning: json['reasoning'] as String?,
      newTitle: json['new_title'] as String?,
    );
  }

  bool get updatedTitle => newTitle != null;
  bool get updatedContext => actions.any((a) => !a.startsWith('Updated title'));
}
