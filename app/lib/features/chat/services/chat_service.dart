import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/stream_event.dart';
import '../models/attachment.dart';
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import '../models/context_file.dart';
import '../models/context_folder.dart';
import '../models/vault_entry.dart';
import '../models/claude_usage.dart';
import '../models/session_transcript.dart';
import '../models/system_prompt_info.dart';
import '../models/prompt_metadata.dart';
import '../models/agent_info.dart';
import '../models/skill_info.dart';
import '../models/mcp_server_info.dart';
import '../models/plugin_info.dart';
import '../models/mcp_tool.dart';
import '../../../core/errors/app_error.dart';

// Import all the extension files as parts
part 'chat_session_service.dart';
part 'chat_context_service.dart';
part 'chat_vault_service.dart';
part 'chat_auth_service.dart';
part 'chat_server_import_service.dart';
part 'chat_claude_code_service.dart';
part 'chat_prompt_service.dart';
part 'chat_migration_service.dart';

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
  final String? apiKey;
  final http.Client _client;

  /// HTTP client accessor for extensions
  http.Client get client => _client;

  /// Timeout for non-streaming HTTP requests
  static const requestTimeout = Duration(seconds: 30);

  /// Maximum message length (100KB) to prevent abuse and memory issues
  static const maxMessageLength = 100000;

  /// Cached headers - invalidated when apiKey changes
  Map<String, String>? _cachedHeaders;
  String? _lastApiKey;

  /// Standard headers for all requests - identifies this as a Parachute app
  Map<String, String> get defaultHeaders {
    if (_cachedHeaders == null || _lastApiKey != apiKey) {
      _lastApiKey = apiKey;
      _cachedHeaders = {
        'Content-Type': 'application/json',
        'User-Agent': 'Parachute-Chat/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };
    }
    return _cachedHeaders!;
  }

  ChatService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  // ============================================================
  // Streaming Chat (Core functionality stays in main file)
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
    String? agentType,  // Agent type for new sessions (e.g., 'orchestrator')
    String? agentPath,  // Path to agent definition file (e.g., 'Daily/.agents/orchestrator.md')
    String? trustLevel,  // Trust level override (full, vault, sandboxed)
    String? model,  // Model override (e.g., 'claude-sonnet-4-5-20250929')
    String? workspaceId,  // Workspace slug for capability filtering
  }) async* {
    // Validate message length
    if (message.length > maxMessageLength) {
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': 'Message too long (${message.length} chars, max $maxMessageLength)'},
      );
      return;
    }

    debugPrint('[ChatService] Starting stream chat');
    debugPrint('[ChatService] Session: ${sessionId ?? "new"}');
    // Security: Only log first 50 chars of message to avoid leaking sensitive content
    debugPrint('[ChatService] Message preview: ${message.substring(0, message.length.clamp(0, 50))}${message.length > 50 ? "..." : ""}');
    debugPrint('[ChatService] priorConversation provided: ${priorConversation != null}');
    if (priorConversation != null) {
      // Security: Only log length, not content
      debugPrint('[ChatService] priorConversation length: ${priorConversation.length} chars');
    }

    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/api/chat'),
    );

    // Use default headers which includes API key
    request.headers.addAll(defaultHeaders);
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
      if (agentType != null) 'agentType': agentType,
      if (agentPath != null) 'agentPath': agentPath,
      if (trustLevel != null) 'trustLevel': trustLevel,
      if (model != null) 'model': model,
      if (workspaceId != null) 'workspaceId': workspaceId,
    };
    debugPrint('[ChatService] Request body keys: ${requestBody.keys.toList()}');
    debugPrint('[ChatService] agentType: $agentType, agentPath: $agentPath');
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
          throw ServerUnreachableError(cause: TimeoutException(
            'Connection to server timed out after ${connectionTimeout.inSeconds}s',
          ));
        },
      );

      if (streamedResponse.statusCode != 200) {
        final error = NetworkError(
          'Server returned ${streamedResponse.statusCode}',
          statusCode: streamedResponse.statusCode,
        );
        yield StreamEvent(
          type: StreamEventType.error,
          data: {'error': error.userMessage},
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
                event.type == StreamEventType.error ||
                event.type == StreamEventType.typedError) {
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
    } on SocketException catch (e) {
      debugPrint('[ChatService] Socket error: $e');
      final error = ServerUnreachableError(cause: e);
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': error.userMessage},
      );
    } on http.ClientException catch (e) {
      debugPrint('[ChatService] HTTP client error: $e');
      final error = NetworkError('Network error', cause: e);
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': error.userMessage},
      );
    } on ServerUnreachableError catch (e) {
      debugPrint('[ChatService] Server unreachable: $e');
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': e.userMessage},
      );
    } catch (e) {
      debugPrint('[ChatService] Stream error: $e');
      yield StreamEvent(
        type: StreamEventType.error,
        data: {'error': e.toString()},
      );
    }
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
