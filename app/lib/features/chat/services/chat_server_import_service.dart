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

