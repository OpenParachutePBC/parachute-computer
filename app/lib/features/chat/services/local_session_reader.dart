import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'para_id_service.dart';

/// Reads chat sessions directly from local vault markdown files.
///
/// This provides a fallback when the agent server is unavailable,
/// allowing users to see their previous chat sessions.
///
/// Sessions are stored in {vault}/{sessions-folder}/*.md with YAML frontmatter.
/// The sessions folder name is configurable via FileSystemService.
class LocalSessionReader {
  final FileSystemService _fileSystem;

  LocalSessionReader(this._fileSystem);

  /// Get the sessions folder name (for relative paths)
  String get sessionsFolderName => _fileSystem.getSessionsFolderName();

  /// Get the path to the sessions folder
  Future<String?> get sessionsPath async {
    try {
      final path = await _fileSystem.getSessionsPath();
      final dir = Directory(path);
      if (await dir.exists()) {
        return path;
      }
      return null;
    } catch (e) {
      debugPrint('[LocalSessionReader] Error getting sessions path: $e');
      return null;
    }
  }

  /// List all local session files
  ///
  /// Scans recursively to include imported sessions in subdirectories.
  Future<List<ChatSession>> getLocalSessions() async {
    try {
      final path = await sessionsPath;
      if (path == null) {
        final folderName = _fileSystem.getSessionsFolderName();
        debugPrint('[LocalSessionReader] No $folderName folder found');
        return [];
      }

      final dir = Directory(path);
      final sessions = <ChatSession>[];

      // Scan recursively to include imported/ subdirectory
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final session = await _parseSessionFile(entity);
            if (session != null) {
              sessions.add(session);
            }
          } catch (e) {
            debugPrint('[LocalSessionReader] Error parsing ${entity.path}: $e');
          }
        }
      }

      // Sort by updated/created date, newest first
      sessions.sort((a, b) {
        final aDate = a.updatedAt ?? a.createdAt;
        final bDate = b.updatedAt ?? b.createdAt;
        return bDate.compareTo(aDate);
      });

      debugPrint('[LocalSessionReader] Found ${sessions.length} local sessions');
      return sessions;
    } catch (e) {
      debugPrint('[LocalSessionReader] Error listing sessions: $e');
      return [];
    }
  }

  /// Parse a session markdown file to extract metadata
  Future<ChatSession?> _parseSessionFile(File file) async {
    final content = await file.readAsString();

    // Parse YAML frontmatter
    if (!content.startsWith('---')) {
      return null;
    }

    final endOfFrontmatter = content.indexOf('---', 3);
    if (endOfFrontmatter == -1) {
      return null;
    }

    final frontmatter = content.substring(3, endOfFrontmatter).trim();
    final metadata = _parseYamlFrontmatter(frontmatter);

    // SIMPLIFIED: sdk_session_id is THE only session ID
    final sessionId = metadata['sdk_session_id'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return null;
    }

    return ChatSession(
      id: sessionId,
      title: metadata['title'] as String? ?? _extractTitleFromFilename(file.path),
      agentPath: metadata['agent'] as String?,
      createdAt: _parseDateTime(metadata['created_at']) ?? file.statSync().changed,
      updatedAt: _parseDateTime(metadata['last_accessed']),
      archived: metadata['archived'] == true,
      isLocal: true,
      source: ChatSourceExtension.fromString(metadata['source'] as String?),
      continuedFrom: metadata['continued_from'] as String?,
      originalId: metadata['original_id'] as String?,
    );
  }

  /// Simple YAML frontmatter parser (handles basic key: value pairs)
  Map<String, dynamic> _parseYamlFrontmatter(String yaml) {
    final result = <String, dynamic>{};

    for (final line in yaml.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final colonIndex = trimmed.indexOf(':');
      if (colonIndex == -1) continue;

      final key = trimmed.substring(0, colonIndex).trim();
      var value = trimmed.substring(colonIndex + 1).trim();

      // Remove quotes if present
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }

      // Parse booleans
      if (value == 'true') {
        result[key] = true;
      } else if (value == 'false') {
        result[key] = false;
      } else if (value.isNotEmpty) {
        result[key] = value;
      }
    }

    return result;
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String _extractTitleFromFilename(String path) {
    final filename = p.basenameWithoutExtension(path);
    // Session files are often named like "2025-12-20_chat-1.md"
    // Try to extract a human-readable title
    if (filename.contains('_')) {
      final parts = filename.split('_');
      if (parts.length >= 2) {
        return parts.sublist(1).join(' ').replaceAll('-', ' ');
      }
    }
    return filename;
  }

  /// Get a specific session with its messages
  ///
  /// Searches recursively to find imported sessions in subdirectories.
  Future<ChatSessionWithLocalMessages?> getSession(String sessionId) async {
    debugPrint('[LocalSessionReader] getSession called with id: $sessionId');
    try {
      final path = await sessionsPath;
      if (path == null) {
        debugPrint('[LocalSessionReader] sessionsPath is null, cannot search');
        return null;
      }

      debugPrint('[LocalSessionReader] Searching in: $path');
      final dir = Directory(path);
      int filesChecked = 0;

      // Search recursively to include imported/ subdirectory
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.md')) {
          filesChecked++;
          final content = await entity.readAsString();
          // SIMPLIFIED: Only search for sdk_session_id (the only session ID we use)
          final patterns = [
            'sdk_session_id: $sessionId',
            "sdk_session_id: '$sessionId'",
            'sdk_session_id: "$sessionId"',
          ];

          for (final pattern in patterns) {
            if (content.contains(pattern)) {
              debugPrint('[LocalSessionReader] Found session in: ${entity.path}');
              debugPrint('[LocalSessionReader] Matched pattern: $pattern');
              final result = await _parseFullSession(entity, sessionId);
              debugPrint('[LocalSessionReader] Parsed ${result?.messages.length ?? 0} messages');
              return result;
            }
          }
        }
      }

      debugPrint('[LocalSessionReader] Session not found after checking $filesChecked files');
      return null;
    } catch (e, st) {
      debugPrint('[LocalSessionReader] Error getting session $sessionId: $e');
      debugPrint('[LocalSessionReader] Stack trace: $st');
      return null;
    }
  }

  /// Parse a full session including messages
  Future<ChatSessionWithLocalMessages?> _parseFullSession(File file, String sessionId) async {
    final content = await file.readAsString();

    // Parse frontmatter
    if (!content.startsWith('---')) return null;
    final endOfFrontmatter = content.indexOf('---', 3);
    if (endOfFrontmatter == -1) return null;

    final frontmatter = content.substring(3, endOfFrontmatter).trim();
    final metadata = _parseYamlFrontmatter(frontmatter);

    final session = ChatSession(
      id: sessionId,
      title: metadata['title'] as String? ?? _extractTitleFromFilename(file.path),
      agentPath: metadata['agent'] as String?,
      createdAt: _parseDateTime(metadata['created_at']) ?? file.statSync().changed,
      updatedAt: _parseDateTime(metadata['last_accessed']),
      archived: metadata['archived'] == true,
      isLocal: true,
      source: ChatSourceExtension.fromString(metadata['source'] as String?),
      continuedFrom: metadata['continued_from'] as String?,
      originalId: metadata['original_id'] as String?,
    );

    // Parse messages from markdown content
    final messagesContent = content.substring(endOfFrontmatter + 3).trim();
    final messages = _parseMessages(messagesContent, sessionId);

    return ChatSessionWithLocalMessages(
      session: session,
      messages: messages,
    );
  }

  /// Parse messages from markdown format
  /// Supports formats:
  /// - New: ### para:abc123def456 Human | 2025-12-20T10:30:00Z
  /// - Legacy: ### User | 10:30 AM (User is treated as Human)
  /// - Import: ### Human | 2025-12-20T10:30:00Z
  List<ChatMessage> _parseMessages(String content, String sessionId) {
    final messages = <ChatMessage>[];

    // Match formats:
    // - ### para:xxxxxxxxxxxx Role | timestamp
    // - ### Role | timestamp
    // Accept both "Human" and "User" as user role (Human is preferred)
    final regex = RegExp(r'### (para:[a-z0-9]+\s+)?(Human|User|Assistant) \| ([^\n]+)\n');
    final matches = regex.allMatches(content).toList();

    debugPrint('[LocalSessionReader] _parseMessages: found ${matches.length} message headers');
    if (matches.isEmpty) {
      // Try to show first 500 chars of content for debugging
      debugPrint('[LocalSessionReader] Content preview: ${content.substring(0, content.length.clamp(0, 500))}...');
    }

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final headerLine = content.substring(match.start, match.end - 1); // Remove trailing \n
      final roleStr = match.group(2)!;
      // Normalize: both "Human" and "User" map to user role
      final role = (roleStr == 'Human' || roleStr == 'User') ? 'user' : 'assistant';
      final timestampStr = match.group(3)!;

      // Extract para ID using ParaIdService
      final paraId = ParaIdService.parseFromH3(headerLine);

      // Get message content (from after this header to next header or end)
      final startIndex = match.end;
      final endIndex = i + 1 < matches.length ? matches[i + 1].start : content.length;
      final messageContent = content.substring(startIndex, endIndex).trim();

      if (messageContent.isNotEmpty) {
        messages.add(ChatMessage.fromMarkdown(
          sessionId: sessionId,
          role: role == 'user' ? MessageRole.user : MessageRole.assistant,
          text: messageContent,
          timestamp: _parseTimestamp(timestampStr) ?? DateTime.now(),
          paraId: paraId,
        ));
      }
    }

    return messages;
  }

  DateTime? _parseTimestamp(String timestamp) {
    // Timestamps are often like "10:30 AM" or "Dec 20, 2025 10:30 AM"
    // This is a simplified parser - full implementation would handle more formats
    try {
      return DateTime.tryParse(timestamp);
    } catch (_) {
      return null;
    }
  }
}

/// A session with its messages, loaded from local files
class ChatSessionWithLocalMessages {
  final ChatSession session;
  final List<ChatMessage> messages;

  const ChatSessionWithLocalMessages({
    required this.session,
    required this.messages,
  });
}
