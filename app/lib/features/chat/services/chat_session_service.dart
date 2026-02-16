part of 'chat_service.dart';

/// Extension for session CRUD operations
extension ChatSessionService on ChatService {
  /// Get all chat sessions
  ///
  /// By default, only non-archived sessions are returned.
  /// Pass [includeArchived: true] to get archived sessions as well.
  /// Pass [search] to filter sessions by title (server-side LIKE query).
  /// Pass [workspaceId] to filter by workspace.
  Future<List<ChatSession>> getSessions({
    bool includeArchived = false,
    String? search,
    String? workspaceId,
  }) async {
    try {
      // Request up to 500 sessions to handle large imports
      final params = <String, String>{
        'limit': '500',
        if (includeArchived) 'archived': 'true',
        if (search != null && search.isNotEmpty) 'search': search,
        if (workspaceId != null) 'workspaceId': workspaceId,
      };
      final uri = Uri.parse('$baseUrl/api/chat').replace(queryParameters: params);

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

  /// Update session configuration (trust level, config overrides)
  ///
  /// [trustLevel] - New trust level: full, vault, sandboxed
  /// [configOverrides] - Config overrides merged into session metadata
  Future<ChatSession> updateSessionConfig(
    String sessionId, {
    String? trustLevel,
    Map<String, dynamic>? configOverrides,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (trustLevel != null) body['trustLevel'] = trustLevel;
      if (configOverrides != null) body['configOverrides'] = configOverrides;

      final response = await client.patch(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/config'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to update session config',
          statusCode: response.statusCode,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error updating session config: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error updating session config: $e');
      throw NetworkError('Network error updating session config', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout updating session config: $e');
      throw ServerUnreachableError(cause: e);
    } catch (e) {
      debugPrint('[ChatService] Error updating session config: $e');
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
    // Retry with backoff — handles race condition where the server's permission
    // handler hasn't registered the pending question yet when the SSE event
    // reaches the app.
    const retryDelays = [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ];

    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        debugPrint('[ChatService] Answering question $requestId (attempt ${attempt + 1})');
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
          // No pending question — may be a timing issue, retry
          debugPrint('[ChatService] No pending question found (attempt ${attempt + 1}): ${response.body}');
          if (attempt < retryDelays.length) {
            await Future.delayed(retryDelays[attempt]);
            continue;
          }
          return false;
        } else {
          debugPrint('[ChatService] Failed to submit answer: ${response.statusCode}');
          return false;
        }
      } catch (e) {
        debugPrint('[ChatService] Error submitting answer (attempt ${attempt + 1}): $e');
        if (attempt < retryDelays.length) {
          await Future.delayed(retryDelays[attempt]);
          continue;
        }
        return false;
      }
    }
    return false;
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

  /// Fetch all available agents from the server.
  Future<List<AgentInfo>> getAgents() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/agents'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get agents',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final list = decoded['agents'] as List<dynamic>? ?? [];
      return list
          .map((e) => AgentInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error fetching agents: $e');
      rethrow;
    }
  }

  /// Get all available skills from the server.
  Future<List<SkillInfo>> getSkills() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/skills'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get skills',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final list = decoded['skills'] as List<dynamic>? ?? [];
      return list
          .map((e) => SkillInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error fetching skills: $e');
      rethrow;
    }
  }

  /// Get all configured MCP servers from the server.
  Future<List<McpServerInfo>> getMcpServers() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/mcps'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get MCP servers',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final list = decoded['servers'] as List<dynamic>? ?? [];
      return list
          .map((e) => McpServerInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error fetching MCP servers: $e');
      rethrow;
    }
  }

  // ============================================================
  // Agent CRUD
  // ============================================================

  /// Create a custom agent on the server.
  Future<Map<String, dynamic>> createAgent({
    required String name,
    String? description,
    required String prompt,
    List<String> tools = const [],
    String? model,
  }) async {
    try {
      final body = <String, dynamic>{
        'name': name,
        'prompt': prompt,
        if (description != null) 'description': description,
        if (tools.isNotEmpty) 'tools': tools,
        if (model != null) 'model': model,
      };
      final response = await client.post(
        Uri.parse('$baseUrl/api/agents'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 409) {
        throw NetworkError('Agent already exists', statusCode: 409);
      }
      if (response.statusCode != 200) {
        throw NetworkError('Failed to create agent', statusCode: response.statusCode);
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error creating agent', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Delete a custom agent from the server.
  Future<void> deleteAgent(String name) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/agents/${Uri.encodeComponent(name)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 403) {
        throw NetworkError('Cannot delete this agent', statusCode: 403);
      }
      if (response.statusCode != 200) {
        throw NetworkError('Failed to delete agent', statusCode: response.statusCode);
      }
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error deleting agent', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  // ============================================================
  // Skill CRUD
  // ============================================================

  /// Create a new skill on the server.
  Future<Map<String, dynamic>> createSkill({
    required String name,
    String? description,
    required String content,
  }) async {
    try {
      final body = <String, dynamic>{
        'name': name,
        'content': content,
        if (description != null) 'description': description,
      };
      final response = await client.post(
        Uri.parse('$baseUrl/api/skills'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 409) {
        throw NetworkError('Skill already exists', statusCode: 409);
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw NetworkError('Failed to create skill', statusCode: response.statusCode);
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error creating skill', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Delete a skill from the server.
  Future<void> deleteSkill(String name) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/skills/${Uri.encodeComponent(name)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to delete skill', statusCode: response.statusCode);
      }
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error deleting skill', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  // ============================================================
  // MCP Server CRUD
  // ============================================================

  /// Add an MCP server configuration.
  Future<Map<String, dynamic>> addMcpServer({
    required String name,
    required Map<String, dynamic> config,
  }) async {
    try {
      final body = <String, dynamic>{
        'name': name,
        ...config,
      };
      final response = await client.post(
        Uri.parse('$baseUrl/api/mcps'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 409) {
        throw NetworkError('MCP server already exists', statusCode: 409);
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw NetworkError('Failed to add MCP server', statusCode: response.statusCode);
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error adding MCP server', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Delete an MCP server configuration.
  Future<void> deleteMcpServer(String name) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/mcps/${Uri.encodeComponent(name)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 403) {
        throw NetworkError('Cannot delete built-in MCP server', statusCode: 403);
      }
      if (response.statusCode != 200) {
        throw NetworkError('Failed to delete MCP server', statusCode: response.statusCode);
      }
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error deleting MCP server', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Test an MCP server connection.
  Future<Map<String, dynamic>> testMcpServer(String name) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/mcps/${Uri.encodeComponent(name)}/test'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw NetworkError('Failed to test MCP server', statusCode: response.statusCode);
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error testing MCP server', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  // ============================================================
  // Plugin CRUD
  // ============================================================

  /// Get all installed plugins from the server.
  Future<List<PluginInfo>> getPlugins() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/plugins'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to get plugins',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final list = decoded['plugins'] as List<dynamic>? ?? [];
      return list
          .map((e) => PluginInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error fetching plugins: $e');
      rethrow;
    }
  }

  /// Install a plugin from a Git URL.
  Future<PluginInfo> installPlugin({
    required String url,
    String? slug,
  }) async {
    try {
      final body = <String, dynamic>{
        'url': url,
        if (slug != null) 'slug': slug,
      };
      final response = await client.post(
        Uri.parse('$baseUrl/api/plugins/install'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 120)); // Longer timeout for git clone

      if (response.statusCode == 400) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        throw NetworkError(
          decoded['detail'] as String? ?? 'Invalid plugin',
          statusCode: 400,
        );
      }
      if (response.statusCode != 200) {
        throw NetworkError('Failed to install plugin', statusCode: response.statusCode);
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final pluginData = decoded['plugin'] as Map<String, dynamic>;
      return PluginInfo.fromJson(pluginData);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error installing plugin', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Uninstall a plugin.
  Future<void> uninstallPlugin(String slug) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/plugins/${Uri.encodeComponent(slug)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 403) {
        throw NetworkError('Cannot delete user plugin', statusCode: 403);
      }
      if (response.statusCode != 200) {
        throw NetworkError('Failed to uninstall plugin', statusCode: response.statusCode);
      }
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error uninstalling plugin', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Update a plugin to latest version.
  Future<PluginInfo> updatePlugin(String slug) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/plugins/${Uri.encodeComponent(slug)}/update'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw NetworkError('Failed to update plugin', statusCode: response.statusCode);
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final pluginData = decoded['plugin'] as Map<String, dynamic>;
      return PluginInfo.fromJson(pluginData);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error updating plugin', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Check if a plugin has updates available.
  Future<Map<String, dynamic>> checkPluginUpdate(String slug) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/plugins/${Uri.encodeComponent(slug)}/check-update'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to check plugin update', statusCode: response.statusCode);
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error checking plugin update', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  // ============================================================
  // Detail Fetch Methods (for enriched capability views)
  // ============================================================

  /// Fetch full agent detail (system prompt, permissions, etc.).
  Future<AgentInfo> getAgentDetail(String name) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/agents/${Uri.encodeComponent(name)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to get agent detail', statusCode: response.statusCode);
      }
      return AgentInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error fetching agent detail', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Fetch full skill detail (content, version, files, etc.).
  Future<SkillInfo> getSkillDetail(String name) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/skills/${Uri.encodeComponent(name)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to get skill detail', statusCode: response.statusCode);
      }
      return SkillInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error fetching skill detail', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Fetch tools exposed by an MCP server.
  Future<List<McpTool>> getMcpTools(String name) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/mcps/${Uri.encodeComponent(name)}/tools'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw NetworkError('Failed to get MCP tools', statusCode: response.statusCode);
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final error = decoded['error'] as String?;
      if (error != null) {
        throw Exception(error);
      }
      final list = decoded['tools'] as List<dynamic>? ?? [];
      return list
          .map((e) => McpTool.fromJson(e as Map<String, dynamic>))
          .toList();
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error fetching MCP tools', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Fetch a skill from a specific plugin.
  Future<SkillInfo> getPluginSkill(String slug, String skillName) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/plugins/${Uri.encodeComponent(slug)}/skills/${Uri.encodeComponent(skillName)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to get plugin skill', statusCode: response.statusCode);
      }
      return SkillInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error fetching plugin skill', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Fetch an agent from a specific plugin.
  Future<AgentInfo> getPluginAgent(String slug, String agentName) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/plugins/${Uri.encodeComponent(slug)}/agents/${Uri.encodeComponent(agentName)}'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError('Failed to get plugin agent', statusCode: response.statusCode);
      }
      return AgentInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } on SocketException catch (e) {
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      throw NetworkError('Network error fetching plugin agent', cause: e);
    } on TimeoutException catch (e) {
      throw ServerUnreachableError(cause: e);
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

  // ============================================================
  // Bot Pairing Request Actions
  // ============================================================

  /// Approve a bot pairing request.
  ///
  /// Adds user to allowlist, clears pending_approval, sends approval message.
  Future<void> approvePairing(String requestId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/bots/pairing/${Uri.encodeComponent(requestId)}/approve'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to approve pairing',
          statusCode: response.statusCode,
        );
      }
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error approving pairing: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error approving pairing: $e');
      throw NetworkError('Network error approving pairing', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout approving pairing: $e');
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Deny a bot pairing request.
  ///
  /// Archives the session and marks request as denied.
  Future<void> denyPairing(String requestId) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/bots/pairing/${Uri.encodeComponent(requestId)}/deny'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw NetworkError(
          'Failed to deny pairing',
          statusCode: response.statusCode,
        );
      }
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error denying pairing: $e');
      throw ServerUnreachableError(cause: e);
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error denying pairing: $e');
      throw NetworkError('Network error denying pairing', cause: e);
    } on TimeoutException catch (e) {
      debugPrint('[ChatService] Timeout denying pairing: $e');
      throw ServerUnreachableError(cause: e);
    }
  }

  /// Get count of pending pairing requests.
  Future<int> getPendingPairingCount() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/bots/pairing/count'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['pending'] as int? ?? 0;
      }
      return 0;
    } catch (e) {
      debugPrint('[ChatService] Error getting pending pairing count: $e');
      return 0;
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
