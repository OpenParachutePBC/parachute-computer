part of 'chat_service.dart';

/// Extension for session CRUD operations
extension ChatSessionService on ChatService {
  /// Get all chat sessions
  ///
  /// By default, only non-archived sessions are returned.
  /// Pass [includeArchived: true] to get archived sessions as well.
  Future<List<ChatSession>> getSessions({bool includeArchived = false}) async {
    try {
      // Request up to 500 sessions to handle large imports
      final uri = includeArchived
          ? Uri.parse('$baseUrl/api/chat?archived=true&limit=500')
          : Uri.parse('$baseUrl/api/chat?limit=500');

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get sessions',
          statusCode: response.statusCode,
        );
      }

      // API returns {"sessions": [...]}
      final decoded = jsonDecode(response.body);
      final List<dynamic> data;
      if (decoded is List) {
        data = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['sessions'] is List) {
        data = decoded['sessions'] as List<dynamic>;
      } else {
        data = [];
      }
      return data
          .map((json) => ChatSession.fromJson(json as Map<String, dynamic>))
          .toList();
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error getting sessions: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error getting sessions: $e');
      throw NetworkError('Network error getting sessions', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout getting sessions: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error getting sessions: $e');
      rethrow;
    }
  }

  /// Get a specific session with messages
  Future<ChatSessionWithMessages?> getSession(String sessionId) async {
    final url = '$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}';
    debugPrint('[ChatService] GET $url');
    try {
      final response = await client.get(
        Uri.parse(url),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      debugPrint('[ChatService] Response: ${response.statusCode}');
      if (response.statusCode == 404) {
        debugPrint('[ChatService] Session not found (404)');
        return null;
      }

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get session',
          statusCode: response.statusCode,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[ChatService] Parsed session: ${data['id']}, messages: ${(data['messages'] as List?)?.length ?? 0}');
      return ChatSessionWithMessages.fromJson(data);
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error getting session $sessionId: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error getting session $sessionId: $e');
      throw NetworkError('Network error getting session', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout getting session $sessionId: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error getting session $sessionId: $e');
      rethrow;
    }
  }

  /// Delete a session
  Future<void> deleteSession(String sessionId) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to delete session',
          statusCode: response.statusCode,
        );
      }
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error deleting session: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error deleting session: $e');
      throw NetworkError('Network error deleting session', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout deleting session: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error deleting session: $e');
      rethrow;
    }
  }

  /// Archive a session
  Future<ChatSession> archiveSession(String sessionId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/archive'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to archive session',
          statusCode: response.statusCode,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error archiving session: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error archiving session: $e');
      throw NetworkError('Network error archiving session', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout archiving session: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error archiving session: $e');
      rethrow;
    }
  }

  /// Unarchive a session
  Future<ChatSession> unarchiveSession(String sessionId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/unarchive'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to unarchive session',
          statusCode: response.statusCode,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error unarchiving session: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error unarchiving session: $e');
      throw NetworkError('Network error unarchiving session', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout unarchiving session: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error unarchiving session: $e');
      rethrow;
    }
  }

  /// Submit answers to a user question (AskUserQuestion tool)
  ///
  /// When Claude asks the user a question via the AskUserQuestion tool,
  /// the client receives a user_question event with a requestId. This
  /// method submits the user's answers back to continue the conversation.
  ///
  /// [sessionId] - The session ID
  /// [requestId] - The request ID from the user_question event
  /// [answers] - Map of question text to selected answer(s)
  ///
  /// Returns true if answers were submitted successfully.
  Future<bool> answerQuestion({
    required String sessionId,
    required String requestId,
    required Map<String, dynamic> answers,
  }) async {
    try {
      debugPrint('[ChatService] Answering question $requestId for session $sessionId');
      final response = await client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/answer'),
        headers: defaultHeaders,
        body: jsonEncode({
          'request_id': requestId,
          'answers': answers,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('[ChatService] Answer submitted successfully');
        return true;
      } else if (response.statusCode == 404) {
        debugPrint('[ChatService] No pending question found: ${response.body}');
        return false;
      } else {
        throw Exception('Failed to submit answer: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error submitting answer: $e');
      return false;
    }
  }

  /// Abort an active streaming session
  /// Returns true if abort was successful, false if no active stream found
  Future<bool> abortStream(String sessionId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/abort'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        debugPrint('[ChatService] Stream aborted for session: $sessionId');
        return true;
      } else if (response.statusCode == 404) {
        // No active stream - already completed or invalid session
        debugPrint('[ChatService] No active stream to abort for: $sessionId');
        return false;
      } else {
        throw NetworkError(
          'Failed to abort stream',
          statusCode: response.statusCode,
        );
      }
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error aborting stream: $e');
      return false;
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error aborting stream: $e');
      return false;
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout aborting stream: $e');
      return false;
    } catch (e) {
      debugPrint('[ChatService] Error aborting stream: $e');
      return false;
    }
  }

  /// Check if a session has an active stream on the server
  ///
  /// This is used when returning to a chat to see if the server
  /// is still processing a response.
  Future<bool> hasActiveStream(String sessionId) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/stream-status'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final active = data['active'] as bool? ?? false;
        debugPrint('[ChatService] Stream status for $sessionId: active=$active');
        return active;
      } else {
        debugPrint('[ChatService] Failed to check stream status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('[ChatService] Error checking stream status: $e');
      return false;
    }
  }

  /// Get all sessions with active streams on the server
  Future<List<String>> getActiveStreams() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/chat/active-streams'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        // New format returns list of stream info objects
        final streamsData = data['streams'] as List<dynamic>?;
        if (streamsData == null) return [];

        // Extract session IDs from stream info objects
        final streams = streamsData
            .map((s) {
              if (s is String) return s;
              if (s is Map) return s['session_id'] as String?;
              return null;
            })
            .whereType<String>()
            .toList();
        debugPrint('[ChatService] Active streams: $streams');
        return streams;
      } else {
        debugPrint('[ChatService] Failed to get active streams: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('[ChatService] Error getting active streams: $e');
      return [];
    }
  }
}

/// A session with its messages
class ChatSessionWithMessages {
  final ChatSession session;
  final List<ChatMessage> messages;

  const ChatSessionWithMessages({
    required this.session,
    required this.messages,
  });

  factory ChatSessionWithMessages.fromJson(Map<String, dynamic> json) {
    final session = ChatSession.fromJson(json);

    final messagesList = json['messages'] as List<dynamic>? ?? [];
    final messages = messagesList.map((m) {
      final msg = m as Map<String, dynamic>;
      return ChatMessage.fromJson({
        ...msg,
        'sessionId': session.id,
      });
    }).toList();

    return ChatSessionWithMessages(
      session: session,
      messages: messages,
    );
  }
}
