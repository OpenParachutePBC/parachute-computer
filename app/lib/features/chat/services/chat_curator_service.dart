part of 'chat_service.dart';

/// Extension for curator operations
extension ChatCuratorService on ChatService {
  /// Get curator info for a chat session
  ///
  /// Returns the curator session and recent task history.
  /// The curator automatically runs after each message to maintain
  /// session titles and update context files.
  Future<CuratorInfo> getCuratorInfo(String sessionId) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 404) {
        // No curator session exists yet
        return const CuratorInfo();
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get curator info: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return CuratorInfo.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting curator info: $e');
      rethrow;
    }
  }

  /// Manually trigger a curator run for a session
  ///
  /// Useful for testing or forcing an update. The curator will
  /// evaluate the conversation and update title as needed.
  /// Returns the task ID of the queued task.
  Future<int> triggerCurator(String sessionId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}/trigger'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to trigger curator: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['task_id'] as int;
    } catch (e) {
      debugPrint('[ChatService] Error triggering curator: $e');
      rethrow;
    }
  }

  /// Get curator conversation messages for a session
  ///
  /// Returns the curator's full conversation history, showing what
  /// context it was fed and how it decided what actions to take.
  /// The curator is a persistent SDK session, so we can view its transcript.
  Future<CuratorMessages> getCuratorMessages(String sessionId) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}/messages'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 404) {
        return const CuratorMessages(messages: [], sdkSessionId: null);
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get curator messages: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return CuratorMessages.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting curator messages: $e');
      rethrow;
    }
  }

  /// Get details of a specific curator task
  Future<CuratorTask?> getCuratorTask(int taskId) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/curator/task/$taskId'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get curator task: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return CuratorTask.fromJson(data['task'] as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ChatService] Error getting curator task: $e');
      rethrow;
    }
  }
}
