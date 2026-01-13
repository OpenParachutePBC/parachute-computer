import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import '../models/context_file.dart';
import '../models/context_folder.dart';
import '../models/prompt_metadata.dart';
import '../models/stream_event.dart';
import '../models/system_prompt_info.dart';
import '../models/vault_entry.dart';
import '../models/session_transcript.dart';
import '../models/curator_session.dart';
import '../models/attachment.dart';

/// Service for communicating with the parachute-base backend
///
/// Uses the simplified 8-endpoint API:
///   POST /api/chat           - Run agent (streaming)
///   GET  /api/chat           - List sessions
///   GET  /api/chat/:id       - Get session
///   DELETE /api/chat/:id     - Delete session
///   GET  /api/modules/:mod/prompt   - Get module prompt
///   PUT  /api/modules/:mod/prompt   - Update module prompt
///   GET  /api/modules/:mod/search   - Search module
///   POST /api/modules/:mod/index    - Rebuild index
class ChatService {
  final String baseUrl;
  final http.Client _client;

  /// Timeout for non-streaming HTTP requests
  static const requestTimeout = Duration(seconds: 30);

  /// Standard headers for all requests - identifies this as a Parachute app
  static const Map<String, String> _defaultHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'Parachute-Chat/1.0',
  };

  ChatService({required this.baseUrl}) : _client = http.Client();

  // ============================================================
  // Sessions
  // ============================================================

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

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get sessions: ${response.statusCode}');
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
      final response = await _client.get(
        Uri.parse(url),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      debugPrint('[ChatService] Response: ${response.statusCode}');
      if (response.statusCode == 404) {
        debugPrint('[ChatService] Session not found (404)');
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to get session: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[ChatService] Parsed session: ${data['id']}, messages: ${(data['messages'] as List?)?.length ?? 0}');
      return ChatSessionWithMessages.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting session $sessionId: $e');
      rethrow;
    }
  }

  /// Delete a session
  Future<void> deleteSession(String sessionId) async {
    try {
      final response = await _client.delete(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to delete session: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error deleting session: $e');
      rethrow;
    }
  }

  /// Archive a session
  Future<ChatSession> archiveSession(String sessionId) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/archive'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to archive session: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ChatService] Error archiving session: $e');
      rethrow;
    }
  }

  /// Unarchive a session
  Future<ChatSession> unarchiveSession(String sessionId) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/unarchive'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to unarchive session: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ChatService] Error unarchiving session: $e');
      rethrow;
    }
  }

  // ============================================================
  // Import
  // ============================================================

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
      final response = await _client.post(
        Uri.parse('$baseUrl/api/import'),
        headers: _defaultHeaders,
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
      final response = await _client.post(
        Uri.parse('$baseUrl/api/import/curate'),
        headers: _defaultHeaders,
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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/import/contexts'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/curator/activity/recent?limit=$limit'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/answer'),
        headers: _defaultHeaders,
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
      final response = await _client.post(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/abort'),
        headers: _defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        debugPrint('[ChatService] Stream aborted for session: $sessionId');
        return true;
      } else if (response.statusCode == 404) {
        // No active stream - already completed or invalid session
        debugPrint('[ChatService] No active stream to abort for: $sessionId');
        return false;
      } else {
        throw Exception('Failed to abort stream: ${response.statusCode}');
      }
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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/chat/${Uri.encodeComponent(sessionId)}/stream-status'),
        headers: _defaultHeaders,
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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/chat/active-streams'),
        headers: _defaultHeaders,
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

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
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

  // ============================================================
  // Module Prompt (System Prompt)
  // ============================================================

  /// Get the module prompt info
  ///
  /// Returns information about the Chat module's system prompt including:
  /// - content: The current prompt text (from CLAUDE.md or default)
  /// - exists: Whether CLAUDE.md exists for this module
  /// - defaultPrompt: The built-in default prompt
  Future<ModulePromptInfo> getModulePrompt({String module = 'chat'}) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/modules/$module/prompt'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.put(
        Uri.parse('$baseUrl/api/modules/$module/prompt'),
        headers: _defaultHeaders,
        body: jsonEncode({'content': content}),
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to save module prompt: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error saving module prompt: $e');
      rethrow;
    }
  }

  // Legacy methods for backward compatibility
  Future<DefaultPromptInfo> getDefaultPrompt() async {
    final info = await getModulePrompt();
    return DefaultPromptInfo(
      content: info.defaultPrompt,
      isActive: !info.exists,
    );
  }

  Future<ClaudeMdInfo> getClaudeMd() async {
    final info = await getModulePrompt();
    return ClaudeMdInfo(
      exists: info.exists,
      content: info.exists ? info.content : null,
    );
  }

  Future<void> saveClaudeMd(String content) async {
    await saveModulePrompt(content);
  }

  // ============================================================
  // Prompt Preview (Transparency)
  // ============================================================

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

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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

  // ============================================================
  // Vault Browsing
  // ============================================================

  /// List directory contents in the vault
  ///
  /// [path] - Relative path within vault (e.g., "", "Projects", "Code/myapp")
  /// Returns entries with metadata including hasClaudeMd for directories
  Future<List<VaultEntry>> listDirectory({String path = ''}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/ls').replace(
        queryParameters: path.isNotEmpty ? {'path': path} : null,
      );

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to list directory: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final entries = data['entries'] as List<dynamic>? ?? [];

      return entries
          .map((e) => VaultEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error listing directory: $e');
      rethrow;
    }
  }

  // ============================================================
  // Context Files
  // ============================================================

  /// Get available context files from Chat/contexts/
  ///
  /// Uses /api/ls to list files, filters for .md files,
  /// and converts to ContextFile objects.
  Future<List<ContextFile>> getContexts() async {
    try {
      final entries = await listDirectory(path: 'Chat/contexts');

      final contextFiles = <ContextFile>[];
      for (final entry in entries) {
        if (entry.isFile && entry.name.endsWith('.md')) {
          // Extract title from filename (remove .md, replace dashes with spaces, title case)
          final filename = entry.name;
          final titleFromName = filename
              .replaceAll('.md', '')
              .replaceAll('-', ' ')
              .split(' ')
              .map((w) =>
                  w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
              .join(' ');

          contextFiles.add(ContextFile(
            path: entry.relativePath,
            filename: filename,
            title: titleFromName,
            description: '', // Could enhance to read first line
            isDefault: filename == 'general-context.md',
            size: entry.size ?? 0,
            modified: entry.lastModified ?? DateTime.now(),
          ));
        }
      }

      // Sort: default first, then alphabetically
      contextFiles.sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        return a.title.compareTo(b.title);
      });

      return contextFiles;
    } catch (e) {
      debugPrint('[ChatService] Error getting contexts: $e');
      rethrow;
    }
  }

  // ============================================================
  // Context Folders (CLAUDE.md hierarchy)
  // ============================================================

  /// Get available context folders (folders with CLAUDE.md)
  ///
  /// Returns folders that can be selected as context for a session.
  Future<List<ContextFolder>> getContextFolders() async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/contexts/folders'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get context folders: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final folders = data['folders'] as List<dynamic>? ?? [];

      return folders
          .map((f) => ContextFolder.fromJson(f as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error getting context folders: $e');
      rethrow;
    }
  }

  /// Get the context chain for selected folders
  ///
  /// Returns the full parent chain of CLAUDE.md files.
  Future<ContextChain> getContextChain(List<String> folderPaths) async {
    try {
      final foldersParam = folderPaths.join(',');
      final response = await _client.get(
        Uri.parse('$baseUrl/api/contexts/chain?folders=$foldersParam'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get context chain: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ContextChain.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting context chain: $e');
      rethrow;
    }
  }

  /// Get context folders for a session
  Future<List<String>> getSessionContextFolders(String sessionId) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/contexts/session/$sessionId'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        return []; // Session may not have contexts set
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final paths = data['folder_paths'] as List<dynamic>? ?? [];
      return paths.cast<String>();
    } catch (e) {
      debugPrint('[ChatService] Error getting session context folders: $e');
      return [];
    }
  }

  /// Set context folders for a session
  Future<void> setSessionContextFolders(
    String sessionId,
    List<String> folderPaths,
  ) async {
    try {
      final response = await _client.put(
        Uri.parse('$baseUrl/api/contexts/session/$sessionId'),
        headers: _defaultHeaders,
        body: jsonEncode({'folder_paths': folderPaths}),
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to set session contexts: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error setting session context folders: $e');
      rethrow;
    }
  }

  // ============================================================
  // File Operations
  // ============================================================

  /// Read a file from the vault via the server API
  ///
  /// [relativePath] - Path relative to vault root (e.g., 'Chat/contexts/general-context.md')
  /// Returns file content and metadata, or null if not found
  Future<VaultFileContent?> readFile(String relativePath) async {
    try {
      final uri = Uri.parse('$baseUrl/api/read').replace(
        queryParameters: {'path': relativePath},
      );

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to read file: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VaultFileContent.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error reading file $relativePath: $e');
      rethrow;
    }
  }

  /// Write a file to the vault via the server API
  ///
  /// [relativePath] - Path relative to vault root (e.g., 'Chat/contexts/my-context.md')
  /// [content] - The file content to write
  Future<void> writeFile(String relativePath, String content) async {
    try {
      final response = await _client.put(
        Uri.parse('$baseUrl/api/write'),
        headers: _defaultHeaders,
        body: jsonEncode({
          'path': relativePath,
          'content': content,
        }),
      ).timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to write file: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error writing file $relativePath: $e');
      rethrow;
    }
  }

  // ============================================================
  // Streaming Chat
  // ============================================================

  /// Send a message and receive streaming response
  /// Returns a stream of events as they arrive
  ///
  /// [systemPrompt] - Custom system prompt for this session
  /// If not provided, the server will use the module's CLAUDE.md or default prompt
  ///
  /// [priorConversation] - For continued conversations, formatted prior messages
  /// that go into the system prompt (not shown in user message)
  ///
  /// [continuedFrom] - ID of the session this continues from (for persistence)
  ///
  /// [workingDirectory] - Working directory for this session (relative to vault)
  /// If provided, the agent operates in this directory and loads its CLAUDE.md
  ///
  /// [contexts] - List of context file paths to load (e.g., ['Chat/contexts/general-context.md'])
  /// If not provided, server uses default context (general-context.md)
  /// [attachments] - List of file attachments to include with the message
  Stream<StreamEvent> streamChat({
    String? sessionId,  // null for new sessions - server will assign ID
    required String message,
    String? systemPrompt,
    String? initialContext,
    String? priorConversation,
    String? continuedFrom,
    String? workingDirectory,
    List<String>? contexts,
    List<ChatAttachment>? attachments,
  }) async* {
    debugPrint('[ChatService] Starting stream chat');
    debugPrint('[ChatService] Session: ${sessionId ?? "new"}');
    debugPrint('[ChatService] Message: ${message.substring(0, message.length.clamp(0, 50))}...');
    debugPrint('[ChatService] priorConversation provided: ${priorConversation != null}');
    if (priorConversation != null) {
      debugPrint('[ChatService] priorConversation length: ${priorConversation.length}');
    }

    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/api/chat'),
    );

    request.headers['Content-Type'] = 'application/json';
    final requestBody = {
      'message': message,
      'sessionId': sessionId ?? 'new',  // 'new' tells server to create new session
      'module': 'chat',
      if (systemPrompt != null) 'systemPrompt': systemPrompt,
      if (initialContext != null) 'initialContext': initialContext,
      if (priorConversation != null) 'priorConversation': priorConversation,
      if (continuedFrom != null) 'continuedFrom': continuedFrom,
      if (workingDirectory != null) 'workingDirectory': workingDirectory,
      if (contexts != null && contexts.isNotEmpty) 'contexts': contexts,
      if (attachments != null && attachments.isNotEmpty) 'attachments': attachments.map((a) => a.toJson()).toList(),
    };
    debugPrint('[ChatService] Request body keys: ${requestBody.keys.toList()}');
    if (attachments != null && attachments.isNotEmpty) {
      debugPrint('[ChatService] Attachments: ${attachments.length} files');
    }
    request.body = jsonEncode(requestBody);

    // Timeouts for streaming requests
    const connectionTimeout = Duration(seconds: 30);
    // Allow generous time for AI thinking and tool execution (e.g., builds, tests)
    const chunkTimeout = Duration(minutes: 3);

    try {
      final streamedResponse = await _client.send(request).timeout(
        connectionTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Connection to server timed out after ${connectionTimeout.inSeconds}s',
          );
        },
      );

      if (streamedResponse.statusCode != 200) {
        yield StreamEvent(
          type: StreamEventType.error,
          data: {'error': 'Server returned ${streamedResponse.statusCode}'},
        );
        return;
      }

      String buffer = '';

      // Add per-chunk timeout to detect stalled connections
      await for (final chunk in streamedResponse.stream
          .timeout(chunkTimeout, onTimeout: (sink) {
            sink.addError(TimeoutException(
              'No data received for ${chunkTimeout.inSeconds}s - connection may be stalled',
            ));
            sink.close();
          })
          .transform(utf8.decoder)) {
        buffer += chunk;

        // Process complete lines (SSE format: data: {...}\n\n)
        while (buffer.contains('\n')) {
          final newlineIndex = buffer.indexOf('\n');
          final line = buffer.substring(0, newlineIndex).trim();
          buffer = buffer.substring(newlineIndex + 1);

          if (line.isEmpty) continue;

          final event = StreamEvent.parse(line);
          if (event != null) {
            debugPrint('[ChatService] Event: ${event.type}');
            yield event;

            if (event.type == StreamEventType.done ||
                event.type == StreamEventType.error) {
              return;
            }
          } else if (line.isNotEmpty && !line.startsWith(':')) {
            // Log unexpected parse failures (ignore SSE comments which start with :)
            debugPrint('[ChatService] Failed to parse SSE line: ${line.substring(0, line.length.clamp(0, 100))}');
          }
        }
      }

      // Process any remaining buffer
      if (buffer.trim().isNotEmpty) {
        final event = StreamEvent.parse(buffer.trim());
        if (event != null) {
          yield event;
        }
      }

      debugPrint('[ChatService] Stream completed');
      // If we get here without a done event, the stream ended unexpectedly
      // Yield a done event so the UI knows streaming has stopped
      yield StreamEvent(
        type: StreamEventType.done,
        data: {'note': 'Stream ended without explicit done event'},
      );
    } catch (e) {
      debugPrint('[ChatService] Stream error: $e');
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': e.toString()},
      );
    }
  }

  // ============================================================
  // Curator Session API
  // ============================================================

  /// Get curator info for a chat session
  ///
  /// Returns the curator session and recent task history.
  /// The curator automatically runs after each message to maintain
  /// session titles and update context files.
  Future<CuratorInfo> getCuratorInfo(String sessionId) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.post(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}/trigger'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/curator/${Uri.encodeComponent(sessionId)}/messages'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/curator/task/$taskId'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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

  // Note: getCuratorMessages method removed.
  // The curator no longer maintains a conversation transcript.
  // It runs as quick agent queries that log to Daily/chat-log/ files.

  // ============================================================
  // Claude Code Session Import
  // ============================================================

  /// Get recent Claude Code sessions across all projects
  /// This is the primary method for the flat-list UI
  Future<List<ClaudeCodeSession>> getRecentClaudeCodeSessions({int limit = 100}) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/claude-code/recent?limit=$limit'),
        headers: _defaultHeaders,
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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/claude-code/projects'),
        headers: _defaultHeaders,
      ).timeout(requestTimeout);

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
      final response = await _client.get(
        Uri.parse('$baseUrl/api/claude-code/sessions?path=${Uri.encodeComponent(projectPath)}'),
        headers: _defaultHeaders,
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

      final response = await _client.get(
        uri,
        headers: _defaultHeaders,
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

      final response = await _client.post(
        uri,
        headers: _defaultHeaders,
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

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}

// ============================================================
// Claude Code Models
// ============================================================

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

/// Content read from a vault file via API
class VaultFileContent {
  final String path;
  final String content;
  final int size;
  final DateTime lastModified;

  const VaultFileContent({
    required this.path,
    required this.content,
    required this.size,
    required this.lastModified,
  });

  factory VaultFileContent.fromJson(Map<String, dynamic> json) {
    return VaultFileContent(
      path: json['path'] as String,
      content: json['content'] as String,
      size: json['size'] as int,
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
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
