part of 'chat_service.dart';

/// Extension for module prompt and system prompt operations
extension ChatPromptService on ChatService {
  /// Get the module prompt info
  ///
  /// Returns information about the Chat module's system prompt including:
  /// - content: The current prompt text (from CLAUDE.md or default)
  /// - exists: Whether CLAUDE.md exists for this module
  /// - defaultPrompt: The built-in default prompt
  Future<ModulePromptInfo> getModulePrompt({String module = 'chat'}) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/modules/$module/prompt'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get module prompt: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ModulePromptInfo.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting module prompt: $e');
      rethrow;
    }
  }

  /// Save module prompt (CLAUDE.md content)
  ///
  /// Creates or updates the CLAUDE.md file in the module's folder.
  /// This will override the built-in default system prompt.
  Future<void> saveModulePrompt(String content, {String module = 'chat'}) async {
    try {
      final response = await client.put(
        Uri.parse('$baseUrl/api/modules/$module/prompt'),
        headers: defaultHeaders,
        body: jsonEncode({'content': content}),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to save module prompt: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error saving module prompt: $e');
      rethrow;
    }
  }

  /// Legacy method for backward compatibility - get default prompt
  Future<DefaultPromptInfo> getDefaultPrompt() async {
    final info = await getModulePrompt();
    return DefaultPromptInfo(
      content: info.defaultPrompt,
      isActive: !info.exists,
    );
  }

  /// Legacy method for backward compatibility - get CLAUDE.md
  Future<ClaudeMdInfo> getClaudeMd() async {
    final info = await getModulePrompt();
    return ClaudeMdInfo(
      exists: info.exists,
      content: info.exists ? info.content : null,
    );
  }

  /// Legacy method for backward compatibility - save CLAUDE.md
  Future<void> saveClaudeMd(String content) async {
    await saveModulePrompt(content);
  }

  /// Preview the full system prompt that would be used for a chat
  ///
  /// This allows users to see exactly what context and instructions
  /// are being provided to the AI, supporting transparency.
  Future<PromptPreviewResult> getPromptPreview({
    String? workingDirectory,
    String? agentPath,
    List<String>? contexts,
  }) async {
    try {
      final queryParams = <String, String>{};
      if (workingDirectory != null) {
        queryParams['workingDirectory'] = workingDirectory;
      }
      if (agentPath != null) {
        queryParams['agentPath'] = agentPath;
      }
      if (contexts != null && contexts.isNotEmpty) {
        queryParams['contexts'] = contexts.join(',');
      }

      final uri = Uri.parse('$baseUrl/api/prompt/preview').replace(
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get prompt preview: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return PromptPreviewResult.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting prompt preview: $e');
      rethrow;
    }
  }
}
